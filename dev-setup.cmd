@echo off
setlocal
cd /d "%~dp0"

rem New Windows machines default to Restricted, so .ps1 files will not run if you
rem type  .\dev-setup.ps1  in PowerShell. This launcher starts PowerShell with
rem Bypass for this file only (does not change your user/machine policy).
rem
rem Usage (same flags as the .ps1):
rem   dev-setup.cmd
rem   dev-setup.cmd -List
rem   dev-setup.cmd -DryRun
rem   dev-setup.cmd -Only node_nvm
rem Elevated (nvm, OpenSSH, RDP):  dev-setup-admin.cmd

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0dev-setup.ps1" %*
exit /b %ERRORLEVEL%
