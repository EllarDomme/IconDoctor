@echo off
rem Double-click friendly launcher: PowerShell's default execution policy
rem blocks .ps1 for most users, so bypass it for this process only.
setlocal
set "SCRIPT=%~dp0bin\IconDoctor.ps1"
if "%~1"=="" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Diagnose
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
)
echo.
pause
