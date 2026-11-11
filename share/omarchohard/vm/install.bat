@echo off
rem omarchohard first-boot script. dockur/windows runs C:\OEM\install.bat once,
rem as an administrator, at the end of Windows setup.

rem 1. WinApps' own setup: RemoteApp registry keys, time sync, network profile.
if exist C:\OEM\winapps-install.bat call C:\OEM\winapps-install.bat

rem 2. The inbox task: applies one-shot requests from the Linux side.
schtasks /Create /F /TN "omarchohard-inbox" /SC MINUTE /MO 1 /RU SYSTEM /RL HIGHEST ^
  /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\OEM\inbox.ps1"

rem 3. Microsoft Office from Microsoft's CDN.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\OEM\office.ps1 > C:\OEM\office.log 2>&1
