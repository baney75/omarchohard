# Install Microsoft Office with the Office Deployment Tool, straight from
# Microsoft's CDN. The product comes from office-product.txt (set by
# `omarchohard desktop install --office ...`). Progress goes to
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

@"
<Configuration>
  <Add OfficeClientEdition="64" Channel="$channel">
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

$setup = Start-Process -Wait -PassThru -FilePath "$work\setup.exe" -ArgumentList '/configure', "$work\config.xml"
if ($setup.ExitCode -ne 0) { throw "setup.exe exited with code $($setup.ExitCode)" }
if (-not (Get-OfficeInfo).version) { throw 'setup.exe finished, but Office is not installed' }

# install.bat says ready once Windows has signed out of its console.
Write-OfficeStatus 'installed'
Write-Output "office: installed $product on channel $channel"
