param(
    [string]$FlutterExe = "flutter",
    [string]$Device = "windows"
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$frontendRoot = Join-Path $projectRoot "frontend"

if (-not (Test-Path $frontendRoot)) {
    throw "前端目录不存在: $frontendRoot"
}

Push-Location $frontendRoot
try {
    & $FlutterExe pub get
    & $FlutterExe run -d $Device
}
finally {
    Pop-Location
}

