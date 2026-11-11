# Install Microsoft Office with the Office Deployment Tool, straight from
# Microsoft's CDN. The product comes from office-product.txt (set by
# `omarchohard desktop install --office ...`).
$ErrorActionPreference = 'Stop'
$product = (Get-Content C:\OEM\office-product.txt -Raw).Trim()
$work = 'C:\OEM\odt'
New-Item -ItemType Directory -Force -Path $work | Out-Null
Invoke-WebRequest -UseBasicParsing -Uri 'https://officecdn.microsoft.com/pr/wsus/setup.exe' -OutFile "$work\setup.exe"

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
