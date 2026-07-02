@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\run-regression.ps1" %*
exit /b %ERRORLEVEL%
