<#
.SYNOPSIS
  Creates the Azure relay for Stride: one resource group and one Web PubSub
  resource on the Free tier (20 connections, 20,000 messages a day, no cost).

.DESCRIPTION
  Without -Apply the script only shows what it would do. With -Apply it creates
  the resources and writes the connection string to bridge/.env (which is
  git-ignored). Run it from the repository root after `az login`.

.EXAMPLE
  ./infra/webpubsub.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000
  ./infra/webpubsub.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -Apply
#>
param(
  [Parameter(Mandatory)] [string] $SubscriptionId,
  [string] $ResourceGroup = 'rg-stride',
  [string] $Name = "stride-$(-join ((97..122) | Get-Random -Count 6 | ForEach-Object { [char]$_ }))",
  [string] $Location = 'westeurope',
  [switch] $Apply
)

$ErrorActionPreference = 'Stop'

$account = az account show --subscription $SubscriptionId --query '{name:name, tenant:tenantId, user:user.name}' -o json | ConvertFrom-Json
if (-not $account) { throw "Subscription $SubscriptionId not found. Run 'az login' first." }

Write-Host ''
Write-Host 'Stride relay' -ForegroundColor Cyan
Write-Host "  subscription   $($account.name) ($SubscriptionId)"
Write-Host "  signed in as   $($account.user)"
Write-Host "  resource group $ResourceGroup ($Location)"
Write-Host "  web pubsub     $Name, SKU Free_F1, 1 unit"
Write-Host ''

$groupExists = (az group exists --name $ResourceGroup --subscription $SubscriptionId) -eq 'true'
Write-Host "  resource group exists already: $groupExists"

if (-not $Apply) {
  Write-Host ''
  Write-Host 'Nothing was created. Add -Apply to create these resources.' -ForegroundColor Yellow
  return
}

az extension add --name webpubsub --upgrade --only-show-errors | Out-Null
if (-not $groupExists) {
  az group create --name $ResourceGroup --location $Location --subscription $SubscriptionId --tags app=stride -o none
}
az webpubsub create --name $Name --resource-group $ResourceGroup --location $Location --sku Free_F1 --unit-count 1 --subscription $SubscriptionId -o none

$conn = az webpubsub key show --name $Name --resource-group $ResourceGroup --subscription $SubscriptionId --query primaryConnectionString -o tsv
if (-not $conn) { throw 'Could not read the connection string.' }

# Windows PowerShell 5.1: Join-Path takes two parts, and Set-Content would add a byte-order mark.
$envFile = Join-Path (Join-Path (Join-Path $PSScriptRoot '..') 'bridge') '.env'
[System.IO.File]::WriteAllText($envFile, "WEBPUBSUB_CONNECTION_STRING=$conn`n")
Write-Host ''
Write-Host "Created $Name. Connection string written to bridge/.env." -ForegroundColor Green
Write-Host 'Next: set "relay": "azure" and "lensUrl" in bridge/config.json, restart the bridge, run "npm run pair".'
Write-Host "To remove everything later: az group delete --name $ResourceGroup --subscription $SubscriptionId"
