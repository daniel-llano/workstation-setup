@echo off
setlocal
cd /d "%~dp0"

rem Same Bypass launcher as dev-setup.cmd, but re-opens an elevated prompt
rem (UAC) so nvm-windows, OpenSSH, and RDP steps can succeed on a new machine.

net session >nul 2>&1
if %errorlevel%==0 goto :run

if "%~1"=="" (
  powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
) else (
  powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs -ArgumentList '%*'"
)
exit /b %ERRORLEVEL%

:run
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0dev-setup.ps1" %*
exit /b %ERRORLEVEL%
