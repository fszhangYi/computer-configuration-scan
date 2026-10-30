@echo off
setlocal EnableExtensions
chcp 65001 >nul
cd /d "%~dp0"
title 电脑配置扫描 · Web
set "PY=%~dp0..\.venv\Scripts\python.exe"
if not exist "%PY%" set "PY=python"
echo [ccs-host] Web  http://127.0.0.1:7040/login
"%PY%" -m ccs_host web --host 127.0.0.1 --port 7040
set "ERR=%ERRORLEVEL%"
echo.
echo Exit code %ERR%. Press any key to close.
pause >nul
exit /b %ERR%
