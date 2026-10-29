<#
.SYNOPSIS
  清理 DSH 桌面版累计的 dsh-auth-* 登录 cookie，修复「Web authentication failed」(HTTP 431)。

.DESCRIPTION
  根因（已在本机二进制里核实）：
    · DSH 桌面版每次启动都用 `--port 0` 让系统分配随机端口
      (@deepseek-ai/dsh-desktop-host/lib/index.js → args: --port 0)；
    · Host 的登录 cookie 名字 = "dsh-auth-" + sha256(authority)，
      authority 含端口 → 每次启动都是一个「新名字」的 cookie
      (@deepseek-ai/dsh-client-connection/lib/index.js → cookieName())；
    · 浏览器 Cookie 不区分端口，所有 dsh-auth-* 都随每个请求发出去；
    · 每条约 224 字节，Node 服务器默认请求头上限 16384 字节
      → 约 72 条后 → 431 → 桌面版报 Web authentication failed。

  只删 name 形如 dsh-auth-% 的 cookie（其余站点登录状态全部保留）。
  先备份、再删除、删完复核；全过程写日志，红字看不清就去看日志。

.PARAMETER Check
  只体检，不修改。

.PARAMETER Force
  DSH 还开着时先结束它（会中断正在跑的会话/任务）。

.PARAMETER Restart
  清理完自动重开 DSH。

.PARAMETER Path
  指定 cookie 库路径（默认走 %APPDATA%，一般不用动；测试用）。

.EXAMPLE
  pwsh -NoProfile -ExecutionPolicy Bypass -File .\dsh-cookie-fix.ps1 -Check
  pwsh -NoProfile -ExecutionPolicy Bypass -File .\dsh-cookie-fix.ps1 -Restart
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$Force,
    [switch]$Restart,
    [string]$Path
)

$ErrorActionPreference = 'Stop'
$script:LogLines = @()

function Say([string]$text, [string]$color = 'Gray') {
    Write-Host $text -ForegroundColor $color
    $script:LogLines += $text
}

function Save-Log {
    try {
        $dir = Split-Path -Parent $PSCommandPath
        $file = Join-Path $dir 'dsh-cookie-fix.log'
        $stamp = "===== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ====="
        @($stamp) + $script:LogLines + '' | Set-Content -LiteralPath $file -Encoding UTF8
    } catch { }
}

$DbPath = $Path
if ([string]::IsNullOrWhiteSpace($DbPath)) {
    $DbPath = Join-Path $env:APPDATA '@deepseek-ai\dsh-desktop\Network\Cookies'
}
$Journal = Join-Path (Split-Path -Parent $DbPath) 'Cookies-journal'
$BytesPerCookie = 224
$HeaderCap = 16384

# 找 DSH 主程序：优先用正在运行的进程，其次常见安装位置（不写死某台机器的路径）
function Find-DshExe {
    $p = Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p -and $p.Path -and (Test-Path -LiteralPath $p.Path)) { return $p.Path }
    $cands = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe'),
        (Join-Path $env:ProgramFiles 'DeepSeek Harness\DeepSeek Harness.exe'),
        'D:\dsh\DeepSeek Harness.exe'
    )
    foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    return $null
}

Say 'DSH cookie 清理工具' 'White'
Say "cookie 库: $DbPath"

try {
    if (-not (Test-Path -LiteralPath $DbPath)) {
        Say "找不到 cookie 库。DSH 是否从未启动过，或装在别处？" 'Red'
        Save-Log; exit 1
    }

    # ---- 1. 占用检测（Chromium 运行时会独占锁住该文件）----
    $locked = $false
    try {
        $fs = [System.IO.File]::Open($DbPath, 'Open', 'ReadWrite', 'None')
        $fs.Close()
    } catch {
        $locked = $true
    }

    $running = @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue)
    if (-not $locked -and $running.Count -gt 0) {
        Say "检测到 $($running.Count) 个 DSH 进程，但 cookie 库没被锁（残留进程，或你用了 -Path 指向别处）——继续。" 'DarkGray'
    }
    if ($locked) {
        Say "DSH 正在运行，cookie 库被独占锁定。" 'Yellow'
        if (-not $Force) {
            Say '请先「彻底退出」DSH（托盘图标也要退出），或加 -Force 让脚本结束它。' 'Yellow'
            Save-Log; exit 2
        }
        Say '按 -Force 结束 DSH ...' 'Yellow'
        if ($running.Count -gt 0) { $running | Stop-Process -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 3
        try {
            $fs = [System.IO.File]::Open($DbPath, 'Open', 'ReadWrite', 'None')
            $fs.Close()
        } catch {
            Say 'cookie 库仍被占用，请手动退出 DSH 后重试。' 'Red'
            Save-Log; exit 2
        }
    }

    # ---- 2. 找 SQLite 解释器 ----
    $python = $null
    foreach ($cand in @('python', 'python3', 'py')) {
        $cmd = Get-Command $cand -ErrorAction SilentlyContinue
        if ($cmd) { $python = $cmd.Source; break }
    }
    if (-not $python) {
        Say '需要 python（自带 sqlite3 模块）来读写 cookie 库，但 PATH 里没找到。' 'Red'
        Say '装一个：winget install Python.Python.3.12，或告诉我，我改用别的方式。' 'Yellow'
        Save-Log; exit 3
    }
    Say "SQLite 执行器: $python"

    $py = @'
import sqlite3, sys
db, mode = sys.argv[1], sys.argv[2]
con = sqlite3.connect(db)
cur = con.cursor()
total = cur.execute("select count(*) from cookies").fetchone()[0]
rows = cur.execute("select name, host_key from cookies where name like 'dsh-auth-%'").fetchall()
print("COOKIES_TOTAL=%d" % total)
print("AUTH_COUNT=%d" % len(rows))
hosts = {}
for name, host in rows:
    hosts[host] = hosts.get(host, 0) + 1
for h, n in sorted(hosts.items(), key=lambda kv: -kv[1])[:5]:
    print("HOST=%s %d" % (h, n))
if mode == "prune":
    cur.execute("delete from cookies where name like 'dsh-auth-%'")
    con.commit()
    cur.execute("vacuum")
    con.commit()
    print("AUTH_LEFT=%d" % cur.execute(
        "select count(*) from cookies where name like 'dsh-auth-%'").fetchone()[0])
con.close()
'@

    # ---- 3. 体检 ----
    Say ''
    Say '== 体检'
    $out = $py | & $python - $DbPath 'check' 2>&1
    $out | ForEach-Object { Say "  $_" }
    if ($LASTEXITCODE -ne 0) {
        Say "python 读取失败（退出码 $LASTEXITCODE），cookie 库可能损坏或版本不符。" 'Red'
        Save-Log; exit 4
    }

    $auth = 0; $total = 0
    foreach ($line in $out) {
        if ("$line" -match '^AUTH_COUNT=(\d+)') { $auth = [int]$Matches[1] }
        if ("$line" -match '^COOKIES_TOTAL=(\d+)') { $total = [int]$Matches[1] }
    }
    $est = $auth * $BytesPerCookie + 8
    $pct = [math]::Round(100.0 * $est / $HeaderCap, 1)
    $color = 'Green'
    if ($pct -ge 80) { $color = 'Red' } elseif ($pct -ge 50) { $color = 'Yellow' }
    Say ("  估算 Cookie 请求头: {0} 字节 / {1} 上限（{2}%）" -f $est, $HeaderCap, $pct) $color
    Say ("  再开约 {0} 次就会撞 431" -f [math]::Max(0, 72 - $auth)) 'DarkGray'

    if ($Check) {
        Say ''
        Say '（-Check：未做任何修改）' 'DarkGray'
        Save-Log; exit 0
    }

    if ($auth -eq 0) {
        Say ''
        Say '没有 dsh-auth-* cookie，无需清理。' 'Green'
        Save-Log; exit 0
    }

    # ---- 4. 先备份（必须在删除之前）----
    $bak = "$DbPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item -LiteralPath $DbPath -Destination $bak -Force
    Say ''
    Say "已备份: $bak" 'Green'

    # ---- 5. 精确删除 + VACUUM ----
    Say '== 清理'
    $out2 = $py | & $python - $DbPath 'prune' 2>&1
    $out2 | ForEach-Object { Say "  $_" }
    if ($LASTEXITCODE -ne 0) {
        Say "清理失败（退出码 $LASTEXITCODE）。备份还在：$bak" 'Red'
        Save-Log; exit 5
    }

    $left = -1
    foreach ($line in $out2) {
        if ("$line" -match '^AUTH_LEFT=(\d+)') { $left = [int]$Matches[1] }
    }

    # ---- 6. 复核 ----
    Say '== 复核'
    $out3 = $py | & $python - $DbPath 'check' 2>&1
    $out3 | ForEach-Object { Say "  $_" }

    if ($left -eq 0) {
        Say ''
        Say '清理完成：dsh-auth-* 已全部移除，其他站点 cookie 保留。' 'Green'
        Say '下次启动 DSH 会自动重新签发一条。' 'DarkGray'
    } else {
        Say "清理后仍剩 $left 条，请把日志发我。" 'Red'
    }

    if ((Test-Path -LiteralPath $Journal) -and ((Get-Item -LiteralPath $Journal).Length -eq 0)) {
        Remove-Item -LiteralPath $Journal -Force -ErrorAction SilentlyContinue
    }

    if ($Restart) {
        $exe = Find-DshExe
        if ($exe) {
            Say "重新启动 DSH: $exe" 'Green'
            Start-Process -FilePath $exe
        } else {
            Say '没找到 DSH 主程序，请手动打开。' 'Yellow'
        }
    }

    Say ''
    Say "日志: $(Join-Path (Split-Path -Parent $PSCommandPath) 'dsh-cookie-fix.log')" 'DarkGray'
    Save-Log
    exit 0
}
catch {
    Say ''
    Say '脚本异常中断：' 'Red'
    Say $_.Exception.Message 'Red'
    Say ($_.ScriptStackTrace) 'DarkGray'
    Save-Log
    exit 99
}
