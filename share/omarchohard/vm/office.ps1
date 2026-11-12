# Install Microsoft Office with the Office Deployment Tool, straight from
# Microsoft's CDN. The product comes from office-product.txt (set by
# `omarchohard desktop install --office ...`).
$ErrorActionPreference = 'Stop'
$product = (Get-Content C:\OEM\office-product.txt -Raw).Trim()
$work = 'C:\OEM\odt'
New-Item -ItemType Directory -Force -Path $work | Out-Null
Invoke-WebRequest -UseBasicParsing -Uri 'https://officecdn.microsoft.com/pr/wsus/setup.exe' -OutFile "$work\setup.exe"

# Run it only if Microsoft signed it.
$sig = Get-AuthenticodeSignature "$work\setup.exe"
if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
  Remove-Item -Force "$work\setup.exe"
  Write-Output "office: refused setup.exe: signature is $($sig.Status), signed by '$($sig.SignerCertificate.Subject)'"
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
  <Updates Enabled="TRUE" />
  <Display Level="None" AcceptEULA="TRUE" />
  <Property Name="AUTOACTIVATE" Value="0" />
</Configuration>
"@ | Set-Content -Encoding UTF8 "$work\config.xml"

Start-Process -Wait -FilePath "$work\setup.exe" -ArgumentList '/configure', "$work\config.xml"
Write-Output "office: installed $product on channel $channel"
