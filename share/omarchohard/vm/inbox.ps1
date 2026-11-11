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
        $a = cscript //nologo $ospp "/inpkey:$key" 2>&1 | Out-String
        $b = cscript //nologo $ospp /act 2>&1 | Out-String
        $out = ($a + $b) -replace [regex]::Escape($key), '*****'
      }
      'windows-key' {
        $a = cscript //nologo "$env:SystemRoot\System32\slmgr.vbs" /ipk $key 2>&1 | Out-String
        $b = cscript //nologo "$env:SystemRoot\System32\slmgr.vbs" /ato 2>&1 | Out-String
        $out = ($a + $b) -replace [regex]::Escape($key), '*****'
      }
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
