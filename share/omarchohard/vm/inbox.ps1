# Applies one-shot requests that `omarchohard desktop activate` drops into the
# shared home folder. Each request is deleted before it is acted on, and the
# result file never contains the key.
$ErrorActionPreference = 'Continue'
$rel = (Get-Content C:\OEM\inbox-path.txt -Raw).Trim()
$inbox = "\\host.lan\Data\$rel"
if (-not (Test-Path $inbox)) { exit 0 }

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
      default { $out = "unknown action: $($req.action)" }
    }
  }
  $key = $null
  Set-Content -Path $resultPath -Value $out
}
