# Applies one-shot requests that `omarchohard desktop activate` and
# `omarchohard desktop update` drop into the shared home folder. Each request
# is deleted before it is acted on, and the result file never contains the key.
$ErrorActionPreference = 'Continue'
. C:\OEM\office-info.ps1
$inbox = Get-Inbox
if (-not $inbox) { exit 0 }

# Office's own updater, and the only channels a request may move Office to.
$c2r = 'C:\Program Files\Common Files\microsoft shared\ClickToRun\OfficeC2RClient.exe'
$channels = @('Current', 'MonthlyEnterprise', 'SemiAnnual')
# Four dot-separated numbers, like 16.0.19328.20100. \z, as $ would also
# accept a trailing newline.
$versionPattern = '^[0-9]+(\.[0-9]+){3}\z'

$ospp = @(
  "$env:ProgramFiles\Microsoft Office\Office16\OSPP.VBS",
  "${env:ProgramFiles(x86)}\Microsoft Office\Office16\OSPP.VBS"
) | Where-Object { Test-Path $_ } | Select-Object -First 1

$licenseStatus = @{
  0 = 'unlicensed'; 1 = 'licensed'; 2 = 'initial grace period'; 3 = 'additional grace period'
  4 = 'non-genuine grace period'; 5 = 'notification'; 6 = 'extended grace period'
}

# Install a key through the licensing service, which takes it as a method
# argument, so it never appears on a command line (slmgr /ipk and OSPP /inpkey
# would put it there). Then activate the product the key belongs to. The text
# returned never contains the key.
function Install-ProductKey([string]$key) {
  try {
    $svc = Get-CimInstance SoftwareLicensingService -ErrorAction Stop
    Invoke-CimMethod -InputObject $svc -MethodName InstallProductKey -Arguments @{ ProductKey = $key } -ErrorAction Stop | Out-Null
    Invoke-CimMethod -InputObject $svc -MethodName RefreshLicenseStatus -ErrorAction SilentlyContinue | Out-Null
  } catch {
    return ("key not installed: " + $_.Exception.Message) -replace [regex]::Escape($key), '*****'
  }
  $lines = Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL" |
    Where-Object { $key.EndsWith($_.PartialProductKey) } | ForEach-Object {
      $product = $_
      try {
        Invoke-CimMethod -InputObject $product -MethodName Activate -ErrorAction Stop | Out-Null
        $now = Get-CimInstance SoftwareLicensingProduct -Filter "ID = '$($product.ID)'"
        "$($product.Name): $($licenseStatus[[int]$now.LicenseStatus])"
      } catch {
        "$($product.Name): key installed, activation failed: $($_.Exception.Message)"
      }
    }
  if (-not $lines) { return 'key installed, but no product with that key was found to activate' }
  ($lines | Out-String) -replace [regex]::Escape($key), '*****'
}

# Ask Office to update now (to $version when given) and Windows Update to
# scan. Both carry on by themselves; the message says they started.
function Start-Update([string]$version) {
  if (-not (Test-Path $c2r)) { return 'Office is not installed yet' }
  $c2rArgs = @('/update', 'user', 'displaylevel=false', 'forceappshutdown=false')
  if ($version) { $c2rArgs += "updatetoversion=$version" }
  Start-Process -FilePath $c2r -ArgumentList $c2rArgs
  Start-Process -FilePath "$env:SystemRoot\System32\UsoClient.exe" -ArgumentList 'StartInteractiveScan'
  $to = if ($version) { " to $version" } else { '' }
  "Office update$to started; Windows Update is checking too"
}

# The answer to an update request: Office's version and channel, and what happened.
function Format-UpdateResult([string]$message) {
  $info = Get-OfficeInfo
  [ordered]@{ version = $info.version; channel = $info.channel; message = $message } | ConvertTo-Json -Compress
}

Get-ChildItem -Path $inbox -Filter '*.request' | ForEach-Object {
  $resultPath = $_.FullName -replace '\.request$', '.result'
  try {
    $req = Get-Content $_.FullName -Raw | ConvertFrom-Json
  } finally {
    Remove-Item -Force $_.FullName
  }
  $key = $req.key
  if ($key -and $key -notmatch '^[A-Z0-9]{5}(-[A-Z0-9]{5}){4}$') { $out = 'rejected: malformed key' }
  else {
    switch ($req.action) {
      'office-key' {
        if (-not $ospp) { $out = 'Office is not installed yet' ; break }
        $out = Install-ProductKey $key
      }
      'windows-key' { $out = Install-ProductKey $key }
      'status' {
        $w = cscript //nologo "$env:SystemRoot\System32\slmgr.vbs" /xpr 2>&1 | Out-String
        $o = if ($ospp) { cscript //nologo $ospp /dstatus 2>&1 | Out-String } else { 'Office: not installed' }
        $out = "Windows:`n$w`nOffice:`n$o"
      }
      'update' {
        if ($req.version -and "$($req.version)" -notmatch $versionPattern) { $out = Format-UpdateResult 'rejected: malformed version'; break }
        $out = Format-UpdateResult (Start-Update "$($req.version)")
      }
      'channel' {
        if ($channels -cnotcontains "$($req.channel)") { $out = Format-UpdateResult 'rejected: unknown channel'; break }
        if ($req.version -and "$($req.version)" -notmatch $versionPattern) { $out = Format-UpdateResult 'rejected: malformed version'; break }
        if (-not (Test-Path $c2r)) { $out = Format-UpdateResult 'Office is not installed yet'; break }
        Start-Process -Wait -FilePath $c2r -ArgumentList '/changesetting', "Channel=$($req.channel)"
        $out = Format-UpdateResult ("channel set to $($req.channel); " + (Start-Update "$($req.version)"))
      }
      default { $out = "unknown action: $($req.action)" }
    }
  }
  $key = $null
  Set-Content -Path $resultPath -Value $out
}

# Office updates itself, so keep the version and channel in
# office-status.json current for `omarchohard doctor` and `desktop status`.
$statusPath = Join-Path $inbox 'office-status.json'
if (Test-Path $statusPath) {
  try { $known = Get-Content $statusPath -Raw | ConvertFrom-Json } catch { $known = $null }
  $now = Get-OfficeInfo
  if ($known.phase -eq 'ready' -and ($known.version -ne $now.version -or $known.channel -ne $now.channel)) {
    Write-OfficeStatus 'ready'
  }
}
