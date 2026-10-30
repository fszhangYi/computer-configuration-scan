@echo off
setlocal
cd /d "%~dp0"
REM Ensure UTF-8 BOM so Windows PowerShell 5.1 reads Chinese correctly
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -Command ^
  "$p='%~dp0Scan-ComputerConfiguration.ps1'; $b=[IO.File]::ReadAllBytes($p); if(-not($b.Length -ge 3 -and $b[0]-eq 0xEF -and $b[1]-eq 0xBB -and $b[2]-eq 0xBF)){ $t=[IO.File]::ReadAllText($p); $utf8=New-Object System.Text.UTF8Encoding $true; [IO.File]::WriteAllText($p,$t,$utf8) }"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Scan-ComputerConfiguration.ps1" %*
echo.
pause
