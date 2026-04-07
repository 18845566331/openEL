$ErrorActionPreference = "Stop"

# Get the directory where the script is located
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Navigate to the root of the repo (assuming script is in scripts/ folder or root)
# Adjust this if script location changes. Assuming d:\opencv缺陷检测 - 副本\el_defect_system\scripts
# But we initiated git in d:\opencv缺陷检测 - 副本
# So we need to go up 2 levels from el_defect_system\scripts

Push-Location "$scriptDir\..\.."
try {
    Write-Host "正在保存代码..."
    git add .
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    git commit -m "Auto save: $timestamp"
    
    Write-Host "代码保存成功! 时间: $timestamp"
}
catch {
    Write-Error "保存失败: $_"
}
finally {
    Pop-Location
    Start-Sleep -Seconds 3
}
