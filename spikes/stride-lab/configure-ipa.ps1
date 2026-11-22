<#
.SYNOPSIS
  Puts your STT server address and key into a downloaded StrideLab.ipa, so the
  app is ready to use as soon as it is installed.

.DESCRIPTION
  Reads STT_URL and STT_API_KEY from bridge/.env and adds them to the app as
  STTConfig.plist, in a copy of the .ipa: StrideLab-configured.ipa. The original
  stays as it is. Run this before signing; the signer then signs the app with
  the file inside.

  The configured .ipa holds your key: keep it private (git ignores *.ipa), copy
  it only to the PC that signs it, and delete it when the app is installed.
  The app stores the key in the iPhone's Keychain on first launch.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File spikes\stride-lab\configure-ipa.ps1
#>
param(
  [string]$Ipa = (Join-Path $PSScriptRoot 'build-out\StrideLab.ipa'),
  [string]$EnvFile = (Join-Path $PSScriptRoot '..\..\bridge\.env')
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

if (-not (Test-Path $Ipa)) { throw "No .ipa at $Ipa. Download it first: gh run download --repo jensvh/stride --name StrideLab --dir spikes\stride-lab\build-out" }
if (-not (Test-Path $EnvFile)) { throw "No $EnvFile. Copy bridge\.env.example to bridge\.env and fill in STT_URL and STT_API_KEY." }

function Read-EnvValue([string]$name) {
  foreach ($line in Get-Content -LiteralPath $EnvFile) {
    if ($line -match "^\s*$name\s*=\s*(.*?)\s*$") { return $Matches[1].Trim('"', "'") }
  }
  return ''
}
$url = Read-EnvValue 'STT_URL'
$key = Read-EnvValue 'STT_API_KEY'
if (-not $url -or -not $key) { throw "Set STT_URL and STT_API_KEY in $EnvFile first." }

$esc = { param($s) [System.Security.SecurityElement]::Escape($s) }
$plist = @"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>STTURL</key>
  <string>$(& $esc $url)</string>
  <key>STTKey</key>
  <string>$(& $esc $key)</string>
</dict>
</plist>
"@

$out = Join-Path (Split-Path $Ipa) 'StrideLab-configured.ipa'
Copy-Item -LiteralPath $Ipa -Destination $out -Force
$zip = [System.IO.Compression.ZipFile]::Open($out, [System.IO.Compression.ZipArchiveMode]::Update)
try {
  $info = $zip.Entries | Where-Object { $_.FullName -match '^Payload/[^/]+\.app/Info\.plist$' } | Select-Object -First 1
  if (-not $info) { throw 'This does not look like an iPhone app: no Payload/*.app/Info.plist inside.' }
  $name = ($info.FullName -replace 'Info\.plist$', '') + 'STTConfig.plist'
  $zip.Entries | Where-Object { $_.FullName -eq $name } | ForEach-Object { $_.Delete() }
  $writer = New-Object System.IO.StreamWriter($zip.CreateEntry($name).Open(), (New-Object System.Text.UTF8Encoding($false)))
  try { $writer.Write($plist) } finally { $writer.Dispose() }
} finally { $zip.Dispose() }

Write-Host ""
Write-Host "Configured app written: $out"
Write-Host "  STT server: $(([Uri]$url).Host)"
Write-Host "  STT key:    added (not shown)"
Write-Host ""
Write-Host "This file holds your key. Copy it only to the PC that signs it, and delete it once the app is installed."
