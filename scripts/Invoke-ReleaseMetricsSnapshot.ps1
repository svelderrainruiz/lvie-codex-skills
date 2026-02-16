param(
  [Parameter(Mandatory = $true)]
  [long]$RunId,

  [Parameter(Mandatory = $false)]
  [string]$OwnerRepo = '',

  [Parameter(Mandatory = $false)]
  [string]$ReleaseTag,

  [Parameter(Mandatory = $false)]
  [string]$OutputDir,

  [Parameter(Mandatory = $false)]
  [bool]$RollbackTriggered = $false,

  [Parameter(Mandatory = $false)]
  [string]$GitHubToken
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'Invoke-ControlPlaneBridge.ps1')

$payload = [ordered]@{
  RunId = $RunId
  OwnerRepo = $OwnerRepo
  ReleaseTag = $ReleaseTag
  OutputDir = $OutputDir
  RollbackTriggered = $RollbackTriggered
  GitHubToken = $GitHubToken
}

Invoke-ControlPlaneBridge -Command 'release-metrics' -Arguments $payload
