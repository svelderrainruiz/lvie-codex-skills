param(
  [Parameter(Mandatory = $false)]
  [string]$MetricsDirectory,

  [Parameter(Mandatory = $false)]
  [int]$MinConsecutiveGreens = 5,

  [Parameter(Mandatory = $false)]
  [string[]]$RequiredLaneNames,

  [Parameter(Mandatory = $false)]
  [string[]]$ShadowLaneNames,

  [Parameter(Mandatory = $false)]
  [string]$RolloutSignature,

  [Parameter(Mandatory = $false)]
  [string]$RunnerPoolSignature,

  [Parameter(Mandatory = $false)]
  [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'Invoke-ControlPlaneBridge.ps1')

$payload = [ordered]@{
  MetricsDirectory = $MetricsDirectory
  MinConsecutiveGreens = $MinConsecutiveGreens
  RequiredLaneNames = $RequiredLaneNames
  ShadowLaneNames = $ShadowLaneNames
  RolloutSignature = $RolloutSignature
  RunnerPoolSignature = $RunnerPoolSignature
  OutputPath = $OutputPath
}

Invoke-ControlPlaneBridge -Command 'shadow-promotion-evaluate' -Arguments $payload
