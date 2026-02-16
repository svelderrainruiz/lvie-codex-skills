param(
  [Parameter(Mandatory = $false)]
  [string]$WorkflowFile = 'windows-linux-vipm-package.yml',

  [Parameter(Mandatory = $false)]
  [string]$Branch,

  [Parameter(Mandatory = $false)]
  [string]$TestPath = './tests/*.Tests.ps1',

  [Parameter(Mandatory = $false)]
  [switch]$SkipLocalTests,

  [Parameter(Mandatory = $false)]
  [string[]]$WorkflowInput,

  [Parameter(Mandatory = $false)]
  [switch]$TriagePackageVipLinux,

  [Parameter(Mandatory = $false)]
  [string]$VipmCliUrl,

  [Parameter(Mandatory = $false)]
  [string]$VipmCliSha256,

  [Parameter(Mandatory = $false)]
  [string]$VipmCliArchiveType = 'tar.gz',

  [Parameter(Mandatory = $false)]
  [int]$PollSeconds = 20,

  [Parameter(Mandatory = $false)]
  [int]$CycleSleepSeconds = 60,

  [Parameter(Mandatory = $false)]
  [int]$MaxCycles = 0,

  [Parameter(Mandatory = $false)]
  [switch]$StopOnFailure,

  [Parameter(Mandatory = $false)]
  [string]$LogPath,

  [Parameter(Mandatory = $false)]
  [ValidateSet('auto', 'runner-cli', 'gh')]
  [string]$DispatchBackend = 'auto',

  [Parameter(Mandatory = $false)]
  [ValidateSet('auto', 'runner-cli', 'gh')]
  [string]$RunQueryBackend = 'auto',

  [Parameter(Mandatory = $false)]
  [string]$OwnerRepo = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'Invoke-ControlPlaneBridge.ps1')

$payload = [ordered]@{
  WorkflowFile = $WorkflowFile
  Branch = $Branch
  TestPath = $TestPath
  SkipLocalTests = $SkipLocalTests.IsPresent
  WorkflowInput = $WorkflowInput
  TriagePackageVipLinux = $TriagePackageVipLinux.IsPresent
  VipmCliUrl = $VipmCliUrl
  VipmCliSha256 = $VipmCliSha256
  VipmCliArchiveType = $VipmCliArchiveType
  PollSeconds = $PollSeconds
  CycleSleepSeconds = $CycleSleepSeconds
  MaxCycles = $MaxCycles
  StopOnFailure = $StopOnFailure.IsPresent
  LogPath = $LogPath
  DispatchBackend = $DispatchBackend
  RunQueryBackend = $RunQueryBackend
  OwnerRepo = $OwnerRepo
}

Invoke-ControlPlaneBridge -Command 'autonomous-loop' -Arguments $payload
