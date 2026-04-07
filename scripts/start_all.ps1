param(
    [string]$VenvDir = "..\.venv",
    [string]$FlutterExe = "flutter"
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$backendScript = Join-Path $PSScriptRoot "start_backend.ps1"
$frontendScript = Join-Path $PSScriptRoot "start_frontend.ps1"

if (-not (Test-Path $backendScript)) {
    throw "未找到后端启动脚本: $backendScript"
}
if (-not (Test-Path $frontendScript)) {
    throw "未找到前端启动脚本: $frontendScript"
}

Write-Host "==> 在新窗口启动后端服务"
Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -File `"$backendScript`" -VenvDir `"$VenvDir`""

Start-Sleep -Seconds 2

Write-Host "==> 启动 Flutter 前端"
& powershell -ExecutionPolicy Bypass -File $frontendScript -FlutterExe $FlutterExe

