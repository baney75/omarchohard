# Shared by office.ps1 and inbox.ps1: where the Linux side's inbox is, which
# Office is installed, and office-status.json, which `omarchohard desktop
# status` and `doctor` read. Nothing here reads or writes a product key.

# The inbox folder in the shared home folder, or $null when the share is not
# reachable yet.
function Get-Inbox {
  $rel = (Get-Content C:\OEM\inbox-path.txt -Raw).Trim()
  $dir = "\\host.lan\Data\$rel"
  if (Test-Path $dir) { return $dir }
  $null
}

# Office's update channels, by the CDN id ClickToRun records.
$OfficeChannelIds = @{
  '492350f6-3a01-4f97-b9c0-c7c6ddf67d60' = 'Current'
  '55336b82-a18d-4dd6-b5f6-9e5095c314a6' = 'MonthlyEnterprise'
  '7ffbc6bf-bc32-4f92-8982-f9dd17fd3114' = 'SemiAnnual'
  '64256afe-f5d9-4f86-8936-8840a6a4f5be' = 'CurrentPreview'
  'b8f9b850-328d-4355-9145-c59439a0c4cf' = 'SemiAnnualPreview'
  '5440fd1f-7ecb-4221-8110-145efaa6372f' = 'BetaChannel'
}

# Version, channel and products of the installed Office, from ClickToRun's
# own record. Empty strings when Office is not installed.
function Get-OfficeInfo {
  $info = [ordered]@{ product = ''; version = ''; channel = '' }
  $c = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -ErrorAction SilentlyContinue
  if (-not $c) { return $info }
  $url = if ($c.UpdateChannel) { "$($c.UpdateChannel)" } else { "$($c.CDNBaseUrl)" }
  $id = ($url.TrimEnd('/') -split '/')[-1]
  $info.product = "$($c.ProductReleaseIds)"
  $info.version = "$($c.VersionToReport)"
  $info.channel = if ($OfficeChannelIds.ContainsKey($id)) { $OfficeChannelIds[$id] } elseif ($url) { 'unknown' } else { '' }
  $info
}

# Phase is installing-office, ready or failed. Written to a temporary file
# and moved into place, so the Linux side never reads half a file, and as
# UTF-8 without a byte order mark, which jq reads. A status that cannot be
# written is skipped: it must never stop the Office install.
function Write-OfficeStatus([string]$phase, [string]$errorText = '') {
  try {
    $dir = Get-Inbox
    if (-not $dir) { return }
    $info = Get-OfficeInfo
    $product = if ($info.product) { $info.product } else { (Get-Content C:\OEM\office-product.txt -Raw).Trim() }
    $status = [ordered]@{
      phase = $phase
      product = $product
      version = $info.version
      channel = $info.channel
      error = $errorText
      updated = (Get-Date).ToUniversalTime().ToString('o')
    }
    $tmp = Join-Path $dir 'office-status.json.tmp'
    [IO.File]::WriteAllText($tmp, ($status | ConvertTo-Json -Compress))
    Move-Item -Force $tmp (Join-Path $dir 'office-status.json')
  } catch {
    Write-Output "office: could not write office-status.json: $($_.Exception.Message)"
  }
}
