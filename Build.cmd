@echo off
setlocal DisableDelayedExpansion
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer\Build-Release.ps1"
set "ubkBuildExit=%ERRORLEVEL%"
if not "%ubkBuildExit%"=="0" echo UBK build failed. See the error above.
exit /b %ubkBuildExit%
