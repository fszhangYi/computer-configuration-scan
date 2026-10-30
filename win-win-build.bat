@echo off
setlocal EnableExtensions
chcp 65001 >nul
cd /d "%~dp0"
title 电脑配置扫描 · Windows 打包
echo [ccs-host] Windows -^> Windows package
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0packaging\build_windows.ps1"
set "ERR=%ERRORLEVEL%"
echo.
echo Exit code %ERR%. Press any key to close.
pause >nul
exit /b %ERR%
