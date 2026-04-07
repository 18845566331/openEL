param(
    [string]$VenvDir = ".venv",
    [string]$BindHost = "127.0.0.1",
    [int]$Port = 5000,
    [switch]$Reload
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$backendRoot = Join-Path $projectRoot "backend"
$venvPython = Join-Path (Join-Path $projectRoot $VenvDir) "Scripts/python.exe"

if (-not (Test-Path $venvPython)) {
    throw "未找到虚拟环境 Python: $venvPython。请先执行 scripts/setup_backend.ps1"
}

$args = @((Join-Path $backendRoot "run_server.py"), "--host", $BindHost, "--port", "$Port")
if ($Reload) {
    $args += "--reload"
}

Write-Host "==> 启动后端服务: http://$BindHost`:$Port"
& $venvPython @args

