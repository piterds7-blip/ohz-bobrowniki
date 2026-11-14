@echo off
title OHZ AfiFarm - pelny eksport
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo.
  echo  Potrzebne uprawnienia administratora - w okienku Windows kliknij TAK.
  powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
echo.
echo  Wysylam pelna historie (400 dni) z AfiFarm do aplikacji...
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0ohz_afi_sync.ps1" -Pelny
echo.
echo  Nacisnij dowolny klawisz, aby zamknac to okno.
pause >nul
