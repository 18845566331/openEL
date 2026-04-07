param(
    [string]$PythonExe = "python",
    [string]$VenvDir = ".venv",
    [switch]$UpgradePip
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$backendRoot = Join-Path $projectRoot "backend"
$venvPath = Join-Path $projectRoot $VenvDir

Write-Host "==> 创建后端虚拟环境: $venvPath"
& $PythonExe -m venv $venvPath

$venvPython = Join-Path $venvPath "Scripts/python.exe"
if (-not (Test-Path $venvPython)) {
    throw "未找到虚拟环境 Python: $venvPython"
}

if ($UpgradePip) {
    Write-Host "==> 升级 pip"
    & $venvPython -m pip install --upgrade pip
}

Write-Host "==> 安装后端依赖"
& $venvPython -m pip install -r (Join-Path $backendRoot "requirements.txt")

Write-Host "==> 完成。启动命令："
Write-Host "$venvPython $(Join-Path $backendRoot 'run_server.py') --host 127.0.0.1 --port 5000"

