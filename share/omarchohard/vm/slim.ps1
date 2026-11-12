# omarchohard slim. Shrinks the Windows VM's disk without removing anything
# Office or its add-ins use, then trims the freed blocks so the VM's disk
# image on Linux shrinks too (dockur attaches it with discard=unmap).
#
# `omarchohard desktop slim` runs it through the agent, which runs as the
# Windows user; dockur's Windows has UAC off, so that user is elevated. It
# is read from the host's home on each run, so an update reaches existing
# VMs with nothing to install in Windows. Each step writes a line to -Log;
# the last line starts with "done". The first boot runs it too, from C:\OEM.
#
# Measured on the test VM (2026-11-12): the disk image went from 21 GB to
# 16 GB, and Word and Excel opened as fast as before (Word 4.95 to 5.25 s
# from a cold boot, against 5.03 to 5.33 s).
param([Parameter(Mandatory)][string]$Log)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

# One slim at a time in the whole VM: the first-boot task and
# `desktop slim` would both be running DISM and compact otherwise.
$created = $false
$mutex = New-Object Threading.Mutex($true, 'Global\omarchohard-slim', [ref]$created)
if (-not $created) {
  Add-Content -LiteralPath $Log -Encoding UTF8 -Value 'busy: a slim is already running in Windows; run desktop slim again once it ends'
  exit 0
}

function Write-Step([string]$Text) {
  Add-Content -LiteralPath $Log -Encoding UTF8 -Value $Text
}
function Get-UsedGB { [math]::Round((Get-PSDrive C).Used / 1GB, 2) }

# Apps Windows 11 ships for home use, and Photos and the Snipping Tool,
# which Office never calls (its Insert > Screenshot is its own). Office,
# the new Teams (MSTeams), the Store, the app installer, Notepad, Paint, the
# calculator, the terminal and Windows Security stay, and so do Sticky
# Notes, To Do, Clipchamp and People, which can hold notes and projects
# kept only on this VM.
$appx = @(
  'Microsoft.549981C3F5F10', 'Microsoft.BingNews', 'Microsoft.BingSearch',
  'Microsoft.BingWeather', 'Microsoft.Copilot', 'Microsoft.GamingApp', 'Microsoft.GetHelp',
  'Microsoft.Getstarted', 'Microsoft.MicrosoftOfficeHub', 'Microsoft.MicrosoftSolitaireCollection',
  'Microsoft.OutlookForWindows', 'Microsoft.PowerAutomateDesktop', 'Microsoft.Windows.DevHome',
  'Microsoft.WindowsAlarms', 'Microsoft.WindowsCamera', 'Microsoft.WindowsFeedbackHub',
  'Microsoft.Windows.Photos', 'Microsoft.ScreenSketch',
  'Microsoft.WindowsMaps', 'Microsoft.WindowsSoundRecorder', 'Microsoft.Xbox.TCUI',
  'Microsoft.XboxGamingOverlay', 'Microsoft.XboxIdentityProvider', 'Microsoft.XboxSpeechToTextOverlay',
  'Microsoft.YourPhone', 'Microsoft.ZuneMusic', 'Microsoft.ZuneVideo', 'MicrosoftCorporationII.QuickAssist',
  'MicrosoftTeams', 'MicrosoftWindows.Client.WebExperience', 'MicrosoftWindows.CrossDevice'
)

$start = Get-UsedGB
Write-Step "start: $start GB used on C:"

$t = Get-UsedGB
$removed = 0
$failed = @()
$provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)
foreach ($name in $appx) {
  foreach ($p in @(Get-AppxPackage -AllUsers -Name $name -ErrorAction SilentlyContinue)) {
    try { Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop; $removed++ }
    catch {
      try { Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop; $removed++ }
      catch { $failed += $name }
    }
  }
  $provisioned | Where-Object DisplayName -EQ $name |
    Remove-AppxProvisionedPackage -Online -AllUsers -ErrorAction SilentlyContinue | Out-Null
}
$left = if ($failed) { ", not removed: $($failed -join ', ')" } else { '' }
Write-Step ("apps: {0} removed, {1:N2} GB freed{2}" -f $removed, ($t - (Get-UsedGB)), $left)

# Hardware a VM never has: Wi-Fi cards and a face sign-in camera. Speech,
# text to speech, handwriting and OCR stay, as Office's Dictate, Read Aloud
# and ink use them.
$t = Get-UsedGB
Get-WindowsCapability -Online -ErrorAction SilentlyContinue |
  Where-Object { $_.State -eq 'Installed' -and $_.Name -match '^(Microsoft\.Windows\.Wifi\.Client\.|Hello\.Face\.)' } |
  ForEach-Object { Remove-WindowsCapability -Online -Name $_.Name -ErrorAction SilentlyContinue | Out-Null }
Write-Step ("drivers for hardware a VM lacks: {0:N2} GB freed" -f ($t - (Get-UsedGB)))

# Windows Update keeps what it downloads in Delivery Optimization's cache
# (8.4 GB on a VM a day old, measured 2026-11-12). Clear it, and keep it
# under 1 GB from now on.
$t = Get-UsedGB
$do = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
New-Item -Path $do -Force | Out-Null
Set-ItemProperty -Path $do -Name DOAbsoluteMaxCacheSize -Type DWord -Value 1
Set-ItemProperty -Path $do -Name DOMaxCacheAge -Type DWord -Value 86400
Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue
Write-Step ("update download cache: {0:N2} GB freed" -f ($t - (Get-UsedGB)))

# Windows keeps about 7 GB back for updates; a VM's disk can grow instead.
$t = Get-UsedGB
DISM /Online /Set-ReservedStorageState /State:Disabled /Quiet | Out-Null
Write-Step ("reserved storage: {0:N2} GB freed" -f ($t - (Get-UsedGB)))

# Superseded update files. /ResetBase means installed updates can no longer
# be uninstalled, which a VM rebuilt from its installer never needs.
$t = Get-UsedGB
DISM /Online /Cleanup-Image /StartComponentCleanup /ResetBase /Quiet | Out-Null
Write-Step ("old updates: {0:N2} GB freed" -f ($t - (Get-UsedGB)))

$t = Get-UsedGB
Stop-Service wuauserv, bits -Force -ErrorAction SilentlyContinue
foreach ($dir in "$env:SystemRoot\SoftwareDistribution\Download", "$env:SystemRoot\Logs\CBS",
  "${env:ProgramFiles(x86)}\Microsoft\EdgeUpdate\Download") {
  Get-ChildItem -Path $dir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}
# Temp files a day old or more: an open Office document keeps its working
# files there.
$day = (Get-Date).AddDays(-1)
foreach ($dir in "$env:SystemRoot\Temp", "$env:SystemDrive\Users\*\AppData\Local\Temp") {
  Get-ChildItem -Path $dir -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object LastWriteTime -LT $day |
    Remove-Item -Force -ErrorAction SilentlyContinue
}
Start-Service wuauserv -ErrorAction SilentlyContinue
powercfg /hibernate off
Write-Step ("downloads, logs and temp files: {0:N2} GB freed" -f ($t - (Get-UsedGB)))

# Windows itself compressed (dockur's images usually are already).
$t = Get-UsedGB
compact /CompactOS:always | Out-Null
Write-Step ("Windows compressed: {0:N2} GB freed" -f ($t - (Get-UsedGB)))

# Office's program files compressed, 4.92 GB into 2.53 GB on the test VM.
# Office's updater writes new files uncompressed, so this runs again on
# each slim.
$dir = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue).InstallationPath
if ($dir) {
  compact /C /S:"$dir" /EXE:XPRESS8K /I /Q | Out-Null
  # The summary of a query covers every file, not only those just compressed.
  $sum = compact /S:"$dir" /Q | Select-String 'total bytes'
  $n = [regex]::Matches("$sum", '[0-9][0-9,]*') | ForEach-Object { [double]($_.Value -replace ',', '') }
  if ($n.Count -ge 2) { Write-Step ("Office compressed: {0:N2} GB stored in {1:N2} GB" -f ($n[0] / 1GB), ($n[1] / 1GB)) }
}

Optimize-Volume -DriveLetter C -ReTrim -ErrorAction SilentlyContinue
Write-Step ("done: {0:N2} GB used, {1:N2} GB freed" -f (Get-UsedGB), ($start - (Get-UsedGB)))
# The first-boot task removes itself once it has run to the end.
schtasks /Delete /TN omarchohard-slim /F 2>$null | Out-Null
$mutex.ReleaseMutex()
