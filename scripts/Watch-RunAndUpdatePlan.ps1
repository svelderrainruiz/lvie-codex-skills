param(
  [Parameter(Mandatory = $true)]
  [long]$RunId,

  [Parameter(Mandatory = $true)]
  [string]$PlanPath,

  [Parameter(Mandatory = $false)]
  [string]$OwnerRepo = '',

  [Parameter(Mandatory = $false)]
  [string]$StatePath,

  [Parameter(Mandatory = $false)]
  [int]$PollSeconds = 30
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'Invoke-ControlPlaneBridge.ps1')

$payload = [ordered]@{
  RunId = $RunId
  PlanPath = $PlanPath
  OwnerRepo = $OwnerRepo
  StatePath = $StatePath
  PollSeconds = $PollSeconds
}

Invoke-ControlPlaneBridge -Command 'release-watch' -Arguments $payload
