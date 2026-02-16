param(
  [Parameter(Mandatory = $true)]
  [long]$RunId,

  [Parameter(Mandatory = $true)]
  [string]$PlanPath,

  [Parameter(Mandatory = $false)]
  [string]$OwnerRepo = '',

  [Parameter(Mandatory = $false)]
  [string]$SkillRepo,

  [Parameter(Mandatory = $false)]
  [string]$ReleaseTag,

  [Parameter(Mandatory = $false)]
  [bool]$RunSelfHosted = $true,

  [Parameter(Mandatory = $false)]
  [bool]$RunBuildSpec = $true,

  [Parameter(Mandatory = $false)]
  [int]$PollSeconds = 30,

  [Parameter(Mandatory = $false)]
  [string]$OutputDir,

  [Parameter(Mandatory = $false)]
  [string]$GitHubToken,

  [Parameter(Mandatory = $false)]
  [switch]$DryRun,

  [Parameter(Mandatory = $false)]
  [ValidateSet('auto', 'runner-cli', 'gh', 'rest')]
  [string]$DispatchBackend = 'auto'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'Invoke-ControlPlaneBridge.ps1')

$payload = [ordered]@{
  RunId = $RunId
  PlanPath = $PlanPath
  OwnerRepo = $OwnerRepo
  SkillRepo = $SkillRepo
  ReleaseTag = $ReleaseTag
  RunSelfHosted = $RunSelfHosted
  RunBuildSpec = $RunBuildSpec
  PollSeconds = $PollSeconds
  OutputDir = $OutputDir
  GitHubToken = $GitHubToken
  DryRun = $DryRun.IsPresent
  DispatchBackend = $DispatchBackend
}

Invoke-ControlPlaneBridge -Command 'release-orchestrator' -Arguments $payload
