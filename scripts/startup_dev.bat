@echo off
chcp 65001 >nul
cd /d "%~dp0"

echo ============================================
echo  EL Defect System - Dev Mode
echo ============================================
echo.
echo [1/2] Starting backend (auto-reload)...

:: Go to parent directory (project root)
cd ..

:: Check Python (use absolute path so it works after cd into backend/)
set PYTHON=%CD%\.venv\Scripts\python.exe
if not exist "%PYTHON%" (
    echo [WARN] venv not found: %PYTHON%
    echo Trying global python...
    set PYTHON=python
)

:: Kill old process on port 5000
echo Cleaning old backend process...
for /f "tokens=5" %%a in ('netstat -aon ^| findstr ":5000 " ^| findstr "LISTENING"') do (
    taskkill /F /PID %%a >nul 2>&1
)
timeout /t 1 /nobreak >nul

:: Start backend in new window (use absolute path for PYTHON)
start "EL-Backend(Dev)" cmd /k "cd /d %CD%\backend && "%PYTHON%" run_server.py --host 127.0.0.1 --port 5000 --reload"

echo Waiting for backend...
timeout /t 3 /nobreak >nul

echo.
echo [2/2] Starting frontend (debug)...
echo.
echo ============================================
echo  Hot-reload: press r + Enter
echo  Hot-restart: press R + Enter
echo  Quit: press q + Enter
echo ============================================
echo.

:: Use junction to avoid Chinese path CMake cache issues
if not exist D:\el_build (
    mklink /J D:\el_build "%~dp0..\frontend"
)

:: Auto-clean stale CMake cache if source path mismatch detected
set "CMAKE_CACHE=D:\el_build\build\windows\x64\CMakeCache.txt"
if exist "%CMAKE_CACHE%" (
    findstr /m "b:/frontend" "%CMAKE_CACHE%" >nul 2>&1
    if not errorlevel 1 (
        echo [INFO] Detected stale CMake cache, cleaning...
        rmdir /s /q "D:\el_build\build" >nul 2>&1
        echo [INFO] CMake cache cleared.
    )
)

cd /d D:\el_build
call flutter run -d windows
pause
