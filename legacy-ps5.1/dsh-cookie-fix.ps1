# DSH Cookie Fixer - PS 5.1 Compatible
$ErrorActionPreference = "Stop"
$success = $false

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host " DeepSeek Harness Cookie Fixer" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""

# 1. Kill process
Write-Host "[1/2] Closing DeepSeek Harness..." -ForegroundColor Yellow
$processes = Get-Process -Name "*deepseek*" -ErrorAction SilentlyContinue
if ($processes) {
    $processes | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Write-Host "  - Process closed." -ForegroundColor Green
} else {
    Write-Host "  - No running process found." -ForegroundColor Green
}

# 2. Clear Cookie
Write-Host "[2/2] Cleaning corrupted cookies..." -ForegroundColor Yellow
$networkPath = Join-Path $env:APPDATA "@deepseek-ai\dsh-desktop\Network"

if (Test-Path $networkPath) {
    $cookieFile = Join-Path $networkPath "Cookies"
    $journalFile = Join-Path $networkPath "Cookies-journal"
    $backupTime = Get-Date -Format "yyyyMMdd_HHmmss"
    
    if (Test-Path $cookieFile) {
        $bakCookie = "$cookieFile.bak_$backupTime"
        Rename-Item -Path $cookieFile -NewName (Split-Path $bakCookie -Leaf) -Force
        Write-Host "  - Backed up and cleaned: Cookies" -ForegroundColor Green
    }
    
    if (Test-Path $journalFile) {
        $bakJournal = "$journalFile.bak_$backupTime"
        Rename-Item -Path $journalFile -NewName (Split-Path $bakJournal -Leaf) -Force
        Write-Host "  - Backed up and cleaned: Cookies-journal" -ForegroundColor Green
    }
    
    $success = $true
} else {
    Write-Host "  - [ERROR] DSH network directory not found." -ForegroundColor Red
    Write-Host "  - Expected path: $networkPath" -ForegroundColor Gray
    Write-Host "  - Please ensure DSH Desktop is installed and run at least once." -ForegroundColor Red
}

Write-Host ""
if ($success) {
    Write-Host ">>> FIX COMPLETED SUCCESSFULLY! <<<" -ForegroundColor Green
    Write-Host "You can now restart DeepSeek Harness." -ForegroundColor Green
} else {
    Write-Host ">>> FIX FAILED. PLEASE CHECK THE ERRORS ABOVE. <<<" -ForegroundColor Red
}
Write-Host ""