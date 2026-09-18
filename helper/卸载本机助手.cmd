@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-helper.ps1" -Uninstall %*
echo.
pause
