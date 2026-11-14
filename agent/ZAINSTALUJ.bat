@echo off
title OHZ AfiFarm - instalacja agenta
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo.
  echo  Potrzebne uprawnienia administratora - w okienku Windows kliknij TAK.
  powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0instaluj.ps1"
echo.
echo  Nacisnij dowolny klawisz, aby zamknac to okno.
pause >nul
