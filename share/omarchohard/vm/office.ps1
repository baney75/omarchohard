# Install Microsoft Office with the Office Deployment Tool. The product comes
# from office-product.txt (set by `omarchohard desktop install --office ...`).
# When office-source.txt names a folder, the host has been downloading
# Office's install files there during Windows Setup, and Office installs from
# that copy; otherwise, or when that install fails, from Microsoft's CDN.
# Progress goes to
# office-status.json in the shared inbox, which `omarchohard desktop status`
# reads: installing-office, then installed (install.bat marks ready after the
# console sign-out) or failed with the reason.
$ErrorActionPreference = 'Stop'
. C:\OEM\office-info.ps1
$product = (Get-Content C:\OEM\office-product.txt -Raw).Trim()
$work = 'C:\OEM\odt'

# The shared folder can take a minute to appear after Windows Setup.
for ($i = 0; $i -lt 12 -and -not (Get-Inbox); $i++) { Start-Sleep -Seconds 5 }
Write-OfficeStatus 'installing-office'
# Any error from here on stops the script; record why first.
trap {
  Write-OfficeStatus 'failed' "$($_.Exception.Message)"
  Write-Output "office: failed: $($_.Exception.Message)"
  exit 1
}

New-Item -ItemType Directory -Force -Path $work | Out-Null
Invoke-WebRequest -UseBasicParsing -Uri 'https://officecdn.microsoft.com/pr/wsus/setup.exe' -OutFile "$work\setup.exe"

# Run it only if Microsoft signed it.
$sig = Get-AuthenticodeSignature "$work\setup.exe"
# Match whole names, so "O=Microsoft Corporation Example" does not pass.
$subject = "$($sig.SignerCertificate.Subject)"
$issuer = "$($sig.SignerCertificate.Issuer)"
if ($sig.Status -ne 'Valid' -or
    $subject -notmatch '(^|,\s*)O=Microsoft Corporation(\s*,|$)' -or
    $issuer -notmatch '(^|,\s*)O=Microsoft Corporation(\s*,|$)' -or
    $issuer -notmatch '(^|,\s*)CN=Microsoft (Windows )?(Code Signing PCA|Windows Production PCA)[^,]*(\s*,|$)') {
  Remove-Item -Force "$work\setup.exe"
  $why = "refused setup.exe: signature is $($sig.Status), signed by '$($sig.SignerCertificate.Subject)'"
  Write-OfficeStatus 'failed' $why
  Write-Output "office: $why"
  exit 1
}

# Every product omarchohard offers is a Retail SKU, and Retail SKUs install from Current.
$channel = 'Current'

# The host's copy: wait for its ready marker, which holds the version, while
# its files keep growing. No growth for 2 minutes, a failed marker or
# anything unexpected means the CDN instead.
#
# Growth is the total size in a listing of the folder, which the host sends
# fresh, at most 10 seconds old. A file's contents are not: Windows keeps a
# file it read over the share open, and the host's later writes never reach
# it (seen on the test VM, 2026-11-13: the progress file read the same for
# 2 minutes while the download went on).
$source = ''
$version = ''
if (Test-Path C:\OEM\office-source.txt) {
  try {
    $dir = (Get-Content C:\OEM\office-source.txt -Raw).Trim()
    $last = $null
    $changed = Get-Date
    while ($true) {
      if (Test-Path "$dir\ready") {
        $v = (Get-Content "$dir\ready" -Raw).Trim()
        if ($v -match '^[0-9]+(\.[0-9]+){3}$') { $source = $dir; $version = $v }
        else { Write-Output "office: the host's copy has no valid version in its ready marker" }
        break
      }
      if (Test-Path "$dir\failed") {
        Write-Output "office: the host could not download Office: $((Get-Content "$dir\failed" -Raw).Trim())"
        break
      }
      $now = 0
      try { $now = [long](Get-ChildItem -LiteralPath "$dir\Office" -Recurse -File -Force -ErrorAction Stop | Measure-Object Length -Sum).Sum } catch { }
      if ($now -ne $last) {
        $last = $now
        $changed = Get-Date
      } elseif (((Get-Date) - $changed).TotalSeconds -ge 120) {
        Write-Output "office: the host's download has not grown for 2 minutes ($last bytes so far)"
        break
      }
      Start-Sleep -Seconds 5
    }
  } catch {
    Write-Output "office: could not use the host's copy: $($_.Exception.Message)"
    $source = ''
  }
}

# config.xml for the CDN, or for the local copy at SOURCEPATH, version
# SOURCEVERSION, which may still fetch a missing file from the CDN.
function Write-OfficeConfig([string]$sourcePath = '', [string]$sourceVersion = '') {
  $attrs = ''
  if ($sourcePath) {
    $attrs = " SourcePath=`"$([Security.SecurityElement]::Escape($sourcePath))`" Version=`"$sourceVersion`" AllowCdnFallback=`"True`""
  }
  @"
<Configuration>
  <Add OfficeClientEdition="64" Channel="$channel"$attrs>
    <Product ID="$product">
      <Language ID="MatchOS" />
      <ExcludeApp ID="Groove" />
      <ExcludeApp ID="Lync" />
    </Product>
  </Add>
  <Updates Enabled="TRUE" Channel="$channel" />
  <Display Level="None" AcceptEULA="TRUE" />
  <Property Name="AUTOACTIVATE" Value="0" />
</Configuration>
"@ | Set-Content -Encoding UTF8 "$work\config.xml"
}

# Run setup.exe once and return its exit code.
function Invoke-OfficeSetup([string]$sourcePath = '', [string]$sourceVersion = '') {
  Write-OfficeConfig $sourcePath $sourceVersion
  $p = Start-Process -Wait -PassThru -FilePath "$work\setup.exe" -ArgumentList '/configure', "$work\config.xml"
  $p.ExitCode
}

$from = "Microsoft's CDN"
$installed = $false
if ($source) {
  Write-Output "office: installing $product $version from the host's copy at $source"
  $code = Invoke-OfficeSetup $source $version
  if ($code -eq 0 -and (Get-OfficeInfo).version) {
    $installed = $true
    $from = "the host's copy at $source"
  } else {
    # A bad local copy never fails the install: once more, from the CDN.
    Write-Output "office: setup.exe with the host's copy exited with code $code; installing from Microsoft's CDN instead"
  }
} else {
  Write-Output "office: installing $product from Microsoft's CDN"
}
if (-not $installed) {
  $code = Invoke-OfficeSetup
  if ($code -ne 0) { throw "setup.exe exited with code $code" }
  if (-not (Get-OfficeInfo).version) { throw 'setup.exe finished, but Office is not installed' }
}

# install.bat says ready once Windows has signed out of its console.
Write-OfficeStatus 'installed'
Write-Output "office: installed $product on channel $channel from $from"
