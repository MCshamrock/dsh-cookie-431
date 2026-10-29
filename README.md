# dsh-cookie-431

> **DeepSeek Harness 桌面版启动报 `Web authentication failed`？**
> 不是网络问题，不是账号问题，是本地 cookie 库里堆了 70 多条没用的登录 cookie，把请求头顶爆了（HTTP 431）。
> 这个仓库给出病因、证据，以及一个只删该删的那部分、会先备份的清理脚本。

![status](https://img.shields.io/badge/verified-0.2.1--rc.3-blue) ![platform](https://img.shields.io/badge/platform-Windows-lightgrey) ![license](https://img.shields.io/badge/license-MIT-green)

---

## 30 秒修复

**第一步：彻底退出 DSH**（连托盘图标一起退，任务管理器里确认 `DeepSeek Harness` 进程没了）。

**第二步：二选一**

- **最简单**：删掉这两个文件，重开 DSH
  ```
  %APPDATA%\@deepseek-ai\dsh-desktop\Network\Cookies
  %APPDATA%\@deepseek-ai\dsh-desktop\Network\Cookies-journal
  ```
  > 路径里是 `@deepseek-ai`，**带 @**。少写 @ 会找不到文件。
  > 副作用：`127.0.0.1` 上所有站点的登录态一起清空（含内嵌浏览器）。

- **推荐**：用本仓库的脚本，只删 `dsh-auth-*`，其他 cookie 一条不动，而且先备份
  ```powershell
  pwsh -NoProfile -ExecutionPolicy Bypass -File .\scripts\dsh-cookie-fix.ps1 -Restart
  ```
  或者直接双击 `scripts\dsh-cookie-fix.cmd`（窗口会停住，报错看得清）。

**第三步**：正常启动 DSH。聊天记录、工作区、插件都在 `.dsh` 目录里，一条都不会丢。

---

## 病因

一句话：**cookie 名字按「主机:端口」生成，而端口每次启动都随机，浏览器又不区分端口。**

### 1. 每次启动都是随机端口

`@deepseek-ai/dsh-desktop-host/lib/index.js`：

```js
args: ["--no-open", "--host", "127.0.0.1", "--port", "0"]
```

`--port 0` = 交给操作系统随便挑一个空闲端口。所以每次启动 authority 都不一样。

### 2. cookie 名 = hash(authority)

`@deepseek-ai/dsh-client-connection/lib/index.js`：

```js
function cookieName(authority) {
  return "dsh-auth-" + b64url(sha256(authority));   // authority = "127.0.0.1:7620"
}
```

端口变了 → 名字变了 → 浏览器认为是**另一个 cookie**，不会覆盖，只会新增。

### 3. 但 Cookie 不区分端口

`127.0.0.1:7620` 和 `127.0.0.1:4046` 是同一个 cookie 域。于是每个发往 `127.0.0.1` 的请求，都会把**历史上所有** `dsh-auth-*` 一起带上。

### 4. 寿命 30 天，没人回收

`cookieMaxAgeDays` 默认 `30`。旧 cookie 要 30 天才过期，而 Chromium 对「过期」只是不再发送，不保证立刻从库里删除。

### 5. 16 KB 天花板

Host 是 Node 的 http 服务，默认 `maxHeaderSize = 16384`。超了直接 `431 Request Header Fields Too Large`，请求根本进不到业务代码。

实测（对本机正在运行的 Host 故意发加长的 Cookie 头）：

```
16300 字节 → 401    （进到鉴权层了，说明头能过）
16360 字节 → 431    （被 Node 挡在门外）
```

### 6. 算一遍

```
名字：dsh-auth- + base64url(sha256)   = 9 + 43  = 52 字节
值  ：v1.<base64(JSON)>.<base64(sig)> = 3 + 124 + 1 + 43 = 171 字节
一条 224 字节，加 "; " 分隔符 → 227 字节
16384 / 227 ≈ 72 条
```

每次启动 +1 条 → **大约第 72 次启动后就开始永久报错**（在 30 天窗口内）。

---

## 自查

**先退出 DSH**（文件被独占锁住，运行时读不了），然后：

```powershell
$db = "$env:APPDATA\@deepseek-ai\dsh-desktop\Network\Cookies"
python -c "import sqlite3,sys;c=sqlite3.connect(sys.argv[1]);n=c.execute('select count(*) from cookies where name like ?',('dsh-auth-%',)).fetchone()[0];print(n)" $db
```

| 条数 | 状态 |
|---|---|
| < 30 | 安全 |
| 30 ~ 55 | 开始积累，不急 |
| 55 ~ 65 | 该清了 |
| ≥ 70 | 随时可能 431 |

请求头体积粗估 ≈ **条数 × 224 字节**，天花板 16384。

---

## 脚本

`scripts/dsh-cookie-fix.ps1` 做的是外科手术：

```
占用检测 → 体检 → 备份 → 只删 name like 'dsh-auth-%' → VACUUM → 复核 →（可选）重开 DSH
```

| 参数 | 作用 |
|---|---|
| `-Check` | 只体检，不修改 |
| `-Force` | DSH 还开着时先结束它（会中断正在跑的任务） |
| `-Restart` | 清理完自动重开 |
| `-Path` | 指定 cookie 库路径（测试用） |

| 退出码 | 含义 |
|---|---|
| 0 | 成功（或无需清理） |
| 2 | DSH 还在运行，什么都没改 |
| 3 | 找不到 python |
| 4 | cookie 库读不出来 |
| 5 | 删除失败 |
| 99 | 脚本异常 |

- 备份落在同目录 `Cookies.bak-<时间戳>`，后悔了改回去即可。
- 每次运行都会写 `scripts\dsh-cookie-fix.log`，红字看不清就翻日志。
- 依赖：Windows + PowerShell 5.1 或 7 + python（自带 sqlite3）。

---

## 长期方案（可选）

让 cookie 活不过几天，就永远堆不到 72 条。在 `~/.dsh/profiles/desktop/cordis.patch.yml` 末尾追加：

```yaml
- id: connection
  name: "@deepseek-ai/dsh-client-connection"
  inject: [webStartup]
  config:
    trustedHosts: !!js ctx.webStartup.trustedHosts
    cookieMaxAgeDays: 3
```

> profile patch 是**整条 config 替换**，不是深合并；字段写漏会让 DSH 起不来。改前先备份。

否则就是隔一两个月跑一次脚本。

---

## 常见疑问

**Q：数据会丢吗？**
不会。聊天记录、工作区、配置、插件都在 `~/.dsh` 里，跟 cookie 库无关。

**Q：重装有用吗？**
基本没用，除非顺手把 `%APPDATA%` 下的数据也清了——那其实就是本页的「方案 A」。

**Q：会不会官方已经修了？**
可能在更新的版本里已改。先跑一次 `-Check`：如果条数很低却照样报错，那就不是这个原因，别乱删。

**Q：对流传说法逐条核对**

| 说法 | 判定 |
|---|---|
| 每次启动多存一条登录 cookie、从不清理 | ✅ |
| 30 天内约 72 次后就会坏 | 🟡 量级对，72 是期望值；端口偶尔被复用会覆盖，实测 65~80 |
| 报 `Web authentication failed` | ✅ |
| 请求头攒到 16 KB 被退回 431 | ✅ 实测阈值 16.3 KB 附近 |
| 「永久打不开」 | ❌ 夸张，删 cookie 立刻恢复 |
| 路径 `%APPDATA%@deepseek-ai\...` | ❌ 少了 @ |

---

## 免责声明

脚本会修改 Electron 的 cookie 数据库。它只删 `name` 以 `dsh-auth-` 开头的记录，并在删除前生成完整备份；但**任何数据操作都有风险**，请自行确认备份存在后再使用。作者不对使用后果承担责任。

## License

MIT
