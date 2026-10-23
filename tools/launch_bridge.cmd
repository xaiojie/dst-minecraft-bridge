@echo off
setlocal
set PYTHONUTF8=1
py -3 -X utf8 "%~dp0launch_bridge.py" %*
exit /b %errorlevel%
