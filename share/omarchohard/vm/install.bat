@echo off
rem omarchohard first-boot script. dockur/windows runs C:\OEM\install.bat once,
rem as an administrator, at the end of Windows setup.

rem 1. WinApps' own setup: RemoteApp registry keys, time sync, network profile.
if exist C:\OEM\winapps-install.bat call C:\OEM\winapps-install.bat

rem WinApps' TimeSync task again, under the same name, through a console host
rem with no window: Windows 11's default terminal ignores -WindowStyle Hidden
rem and shows an "Administrator: powershell.exe" window at every sign-in.
if exist %windir%\TimeSync.ps1 schtasks /Create /F /TN "TimeSync" /SC ONLOGON /RL HIGHEST ^
  /TR "conhost.exe --headless powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"%windir%\TimeSync.ps1\""

rem 2. The inbox task: applies one-shot requests from the Linux side.
schtasks /Create /F /TN "omarchohard-inbox" /SC MINUTE /MO 1 /RU SYSTEM /RL HIGHEST ^
  /TR "conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\OEM\inbox.ps1"

rem The shared folder changes from Linux, behind Samba's back, so Windows must
rem not trust a cached listing of it: without this the inbox task never sees
rem a request from omarchohard desktop update or activate.
powershell.exe -NoProfile -Command "Set-SmbClientConfiguration -DirectoryCacheLifetime 0 -FileNotFoundCacheLifetime 0 -FileInfoCacheLifetime 0 -Force"

rem 3. Microsoft Office from Microsoft's CDN. office.ps1 writes "installed" (or
rem "failed") to office-status.json before it returns.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\OEM\office.ps1 > C:\OEM\office.log 2>&1

rem A VM never hibernates, so drop hiberfil.sys and the gigabytes it holds.
powercfg /hibernate off

rem Shrink the disk: apps for home use, update downloads, Office compressed
rem (21 GB to 15 GB on the test VM). A SYSTEM task, started now, so the
rem sign-out and "ready" do not wait for it; it runs again at each start
rem until it finishes once, then deletes itself. `omarchohard desktop slim`
rem runs the same script.
schtasks /Create /F /TN "omarchohard-slim" /SC ONSTART /RU SYSTEM /RL HIGHEST ^
  /TR "conhost.exe --headless powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\OEM\slim.ps1 -Log C:\OEM\slim.log"
schtasks /Run /TN "omarchohard-slim"

rem 4. Sign out of the console, last. dockur signs the user in automatically
rem after setup, and while that console session is open a RemoteApp shows
rem "Another user is signed in" instead of the app. Automatic sign-in stays
rem off, so the next boot leaves the session free for RemoteApp.
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /t REG_SZ /d 0 /f
rem Automatic sign-in kept the password in plain text here; it is not needed now.
reg delete "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DefaultPassword /f
rem Ready only now, so omarchohard adds the apps after the console is free.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ". C:\OEM\office-info.ps1; if ((Get-OfficeInfo).version) { Write-OfficeStatus 'ready' }"
shutdown /l /f
