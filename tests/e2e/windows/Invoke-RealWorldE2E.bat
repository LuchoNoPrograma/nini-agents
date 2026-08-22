@echo off
rem Real-world E2E harness for nini-agents: real binaries, sandboxed homes.
rem Thin wrapper; all logic lives in Invoke-RealWorldE2E.ps1 (same folder).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-RealWorldE2E.ps1" %*
exit /b %ERRORLEVEL%
