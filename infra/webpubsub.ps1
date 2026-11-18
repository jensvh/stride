<#
.SYNOPSIS
  Creates the Azure relay for Stride: one resource group and one Web PubSub
  resource on the Free tier (20 connections, 20,000 messages a day, no cost).

.DESCRIPTION
  Without -Apply the script only reads: it shows the current state and the
  exact commands it would run. With -Apply it runs them and writes the
  connection string to bridge/.env (which is git-ignored). Run it from the
  repository root after `az login`.

.EXAMPLE
  ./infra/webpubsub.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -Name stride-relay-abcde
  ./infra/webpubsub.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -Name stride-relay-abcde -Apply
#>
param(
  [Parameter(Mandatory)] [string] $SubscriptionId,
  # Becomes <name>.webpubsub.azure.com, so it must be unique across Azure.
  [string] $Name = "stride-relay-$(-join ((97..122) | Get-Random -Count 5 | ForEach-Object { [char]$_ }))",
  [string] $ResourceGroup = 'rg-stride',
  [string] $Location = 'westeurope',
  [switch] $Apply
)

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 does not stop on a failing native command by itself.
function Invoke-Az {
  & az @args
  if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed (exit $LASTEXITCODE)" }
}

$account = Invoke-Az account show --subscription $SubscriptionId --query '{name:name, tenant:tenantDisplayName}' -o json | ConvertFrom-Json
$groupExists = (Invoke-Az group exists --name $ResourceGroup --subscription $SubscriptionId) -eq 'true'
$provider = Invoke-Az provider show --namespace Microsoft.SignalRService --subscription $SubscriptionId --query registrationState -o tsv
$existing = Invoke-Az resource list --subscription $SubscriptionId --resource-type Microsoft.SignalRService/WebPubSub --query "[?name=='$Name'] | length(@)" -o tsv

$commands = @()
if ($provider -ne 'Registered') {
  $commands += "az provider register --namespace Microsoft.SignalRService --subscription $SubscriptionId --wait"
}
if (-not $groupExists) {
  $commands += "az group create --name $ResourceGroup --location $Location --subscription $SubscriptionId --tags app=stride"
}
if ($existing -eq '0') {
  $commands += "az webpubsub create --name $Name --resource-group $ResourceGroup --location $Location --sku Free_F1 --unit-count 1 --subscription $SubscriptionId --tags app=stride"
}

Write-Host ''
Write-Host 'Stride relay' -ForegroundColor Cyan
Write-Host "  subscription      $($account.name) ($SubscriptionId)"
Write-Host "  tenant            $($account.tenant)"
Write-Host "  resource group    $ResourceGroup in $Location (exists: $groupExists)"
Write-Host "  web pubsub        $Name, Free_F1, 1 unit (exists: $($existing -ne '0'))"
Write-Host "  resource provider Microsoft.SignalRService: $provider"
Write-Host ''
Write-Host 'Commands:' -ForegroundColor Cyan
if ($commands.Count -eq 0) { Write-Host '  none, everything exists already' }
$commands | ForEach-Object { Write-Host "  $_" }
Write-Host "  then: read the connection string into bridge/.env (az webpubsub key show)"
Write-Host ''
Write-Host 'To undo:' -ForegroundColor Cyan
Write-Host "  az group delete --name $ResourceGroup --subscription $SubscriptionId --yes"
if ($provider -ne 'Registered') {
  Write-Host "  az provider unregister --namespace Microsoft.SignalRService --subscription $SubscriptionId"
}

if (-not $Apply) {
  Write-Host ''
  Write-Host 'Nothing was changed. Add -Apply to run the commands above.' -ForegroundColor Yellow
  return
}

Invoke-Az extension add --name webpubsub --upgrade --only-show-errors | Out-Null
if ($provider -ne 'Registered') {
  Invoke-Az provider register --namespace Microsoft.SignalRService --subscription $SubscriptionId --wait
}
if (-not $groupExists) {
  Invoke-Az group create --name $ResourceGroup --location $Location --subscription $SubscriptionId --tags app=stride -o none
}
if ($existing -eq '0') {
  Invoke-Az webpubsub create --name $Name --resource-group $ResourceGroup --location $Location --sku Free_F1 --unit-count 1 --subscription $SubscriptionId --tags app=stride -o none
}

$conn = Invoke-Az webpubsub key show --name $Name --resource-group $ResourceGroup --subscription $SubscriptionId --query primaryConnectionString -o tsv
if (-not $conn) { throw 'Could not read the connection string.' }

# Windows PowerShell 5.1: Join-Path takes two parts, and Set-Content would add a byte-order mark.
$envFile = Join-Path (Join-Path (Join-Path $PSScriptRoot '..') 'bridge') '.env'
[System.IO.File]::WriteAllText($envFile, "WEBPUBSUB_CONNECTION_STRING=$conn`n")
Write-Host ''
Write-Host "Ready: $Name. Connection string written to bridge/.env." -ForegroundColor Green
Write-Host 'Next: set "relay": "azure" in bridge/config.json, restart the bridge, run "npm run pair".'
