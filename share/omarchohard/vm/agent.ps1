# omarchohard agent. Runs in the Windows session of the one hidden FreeRDP
# RemoteApp connection omarchohard keeps open, so opening an app or a file
# needs no new RDP connection: the host writes a request file to a queue
# folder in its own home, and this script starts the program within a tenth
# of a second. Every window it starts shows through that connection.
#
# The queue is read over the RDP drive (\\tsclient\home), never the network
# share, so no SMB cache can hide a request. This script is read from the
# host's home on each start, so an update reaches existing VMs with nothing
# to install in Windows.
#
# A request is one line: VERB<TAB>ARG.
#   word excel powerpoint outlook onenote   start the app; ARG, if any, is a file
#   run                                     open the file ARG with its Windows program
#   uri                                     open an ms-word:, ms-excel:,
#                                           ms-powerpoint: or onenote: link
# Files are \\tsclient\home\... or \\tsclient\media\... paths.
#
# -Warm names apps to keep started and hidden once Office is signed in, so
# opening a file in them is a document window, not a program start (measured
# on the test VM, 2026-11-12: Word 1.17 s cold, 0.24 s warm).
param(
  [Parameter(Mandatory)][string]$Queue,
  [string]$Warm = '',
  [int]$IdleMinutes = 15
)
$ErrorActionPreference = 'Stop'

# One agent per Windows session. A reconnect that starts a second one while
# the first is still running leaves the first in charge.
$created = $false
$mutex = New-Object Threading.Mutex($true, 'Local\omarchohard-agent', [ref]$created)
if (-not $created) { exit 0 }

$log = Join-Path $Queue 'agent.log'
function Write-AgentLog([string]$Text) {
  try { Add-Content -LiteralPath $log -Encoding UTF8 -Value ((Get-Date -Format 'HH:mm:ss.fff') + ' ' + $Text) } catch {}
}

$c2r = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
$officeDir = if ($c2r.InstallationPath) { Join-Path $c2r.InstallationPath 'root\Office16' } else { "$env:ProgramFiles\Microsoft Office\root\Office16" }
$exe = @{
  word = 'WINWORD'; excel = 'EXCEL'; powerpoint = 'POWERPNT'
  outlook = 'OUTLOOK'; onenote = 'ONENOTE'
}
# Started hidden with these, each app waits with no window until a file
# opens in it.
$warmArgs = @{ word = @('/q', '/n'); excel = @(); powerpoint = @() }

function Assert-HostPath([string]$Path) {
  if ($Path -notmatch '^\\\\tsclient\\(home|media)\\' -or ($Path -split '\\') -contains '..') {
    throw "refused path: $Path"
  }
  $Path
}

function Invoke-Request([string]$Line) {
  $verb, $arg = $Line -split "`t", 2
  if ($verb -eq 'run') {
    Start-Process -FilePath (Assert-HostPath $arg)
  } elseif ($verb -eq 'uri') {
    if ($arg -notmatch '^(ms-(word|excel|powerpoint)|onenote):') { throw "refused link: $arg" }
    Start-Process -FilePath $arg
  } elseif ($exe.ContainsKey($verb)) {
    $program = Join-Path $officeDir ($exe[$verb] + '.EXE')
    if ($arg) { Start-Process -FilePath $program -ArgumentList ('"' + (Assert-HostPath $arg) + '"') }
    else { Start-Process -FilePath $program }
  } else {
    throw "unknown request: $verb"
  }
}

# Microsoft 365 shows a sign-in window on start until someone signs in, so
# warm apps wait for a signed-in identity. Other editions sign in with a key.
function Test-OfficeSignedIn {
  if ("$($c2r.ProductReleaseIds)" -notmatch 'O365') { return $true }
  [bool](Get-ChildItem 'HKCU:\Software\Microsoft\Office\16.0\Common\Identity\Identities' -ErrorAction SilentlyContinue)
}

$warmPids = @{}
function Start-WarmApps {
  if (-not $Warm -or -not (Test-OfficeSignedIn)) { return }
  foreach ($app in ($Warm -split ',')) {
    if (-not $warmArgs.ContainsKey($app)) { continue }
    if (Get-Process -Name $exe[$app] -ErrorAction SilentlyContinue) { continue }
    $program = Join-Path $officeDir ($exe[$app] + '.EXE')
    $a = $warmArgs[$app]
    $p = if ($a.Count) { Start-Process -FilePath $program -ArgumentList $a -WindowStyle Hidden -PassThru }
    else { Start-Process -FilePath $program -WindowStyle Hidden -PassThru }
    $warmPids[$p.Id] = $app
    Write-AgentLog "warm $app"
  }
}

# Office with a window on screen counts as use, so the agent stays while
# you work. A hidden warm app does not.
function Test-OfficeInUse {
  [bool](Get-Process -Name $exe.Values -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 })
}

$beat = Join-Path $Queue 'agent.beat'
$last = [DateTime]::UtcNow
$lastBeat = [DateTime]::MinValue
$lastWarm = [DateTime]::MinValue
$lastRequest = [DateTime]::MinValue
Write-AgentLog "started, Office in $officeDir"
while (([DateTime]::UtcNow - $last).TotalMinutes -lt $IdleMinutes) {
  try { $files = [IO.Directory]::GetFiles($Queue, '*.go') } catch { $files = @() }
  foreach ($f in ($files | Sort-Object)) {
    # Claimed by a rename: the host takes back a late request the same way,
    # so only one side ever gets it.
    try {
      [IO.File]::Move($f, "$f.run")
      $line = ([IO.File]::ReadAllText("$f.run")).TrimEnd("`r", "`n")
      [IO.File]::Delete("$f.run")
    } catch { continue }
    try { Invoke-Request $line; Write-AgentLog "ok $line" }
    catch { Write-AgentLog "error $line : $($_.Exception.Message)" }
    $last = $lastRequest = [DateTime]::UtcNow
  }
  $now = [DateTime]::UtcNow
  if (($now - $lastBeat).TotalSeconds -ge 2) {
    try { [IO.File]::WriteAllText($beat, [string]$PID) } catch {}
    $lastBeat = $now
    if (Test-OfficeInUse) { $last = $now }
  }
  # A request goes first; warming waits for a quiet moment.
  if (($now - $lastWarm).TotalSeconds -ge 10 -and ($now - $lastRequest).TotalSeconds -ge 3) {
    Start-WarmApps
    $lastWarm = $now
  }
  Start-Sleep -Milliseconds 100
}
Write-AgentLog 'idle, exiting'
# Warm apps nobody opened a file in go too, so the session can end and the
# VM can pause.
foreach ($id in $warmPids.Keys) {
  $p = Get-Process -Id $id -ErrorAction SilentlyContinue
  if ($p -and $p.MainWindowHandle -eq 0) { Stop-Process -Id $id -Force }
}
try { [IO.File]::Delete($beat) } catch {}
$mutex.ReleaseMutex()
