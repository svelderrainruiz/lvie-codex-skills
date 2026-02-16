#Requires -Version 7.0

param(
  [Parameter(Mandatory = $false)]
  [string]$OwnerRepo = '',

  [Parameter(Mandatory = $false)]
  [string]$WorkflowFile = 'ci.yml',

  [Parameter(Mandatory = $false)]
  [string]$Branch = 'main',

  [Parameter(Mandatory = $false)]
  [ValidateRange(1, 50)]
  [int]$MinConsecutiveGreens = 5,

  [Parameter(Mandatory = $false)]
  [ValidateRange(5, 200)]
  [int]$MaxRunsToScan = 40,

  [Parameter(Mandatory = $false)]
  [string]$ShadowLaneName = 'build-ppl-container-linux-x86-shadow',

  [Parameter(Mandatory = $false)]
  [string]$ShadowDiagnosticsArtifactPrefix = 'docker-contract-ppl-container-linux-x86-shadow-diagnostics-',

  [Parameter(Mandatory = $false)]
  [string]$MetricsDirectory = '',

  [Parameter(Mandatory = $false)]
  [string]$StateOutputPath = '',

  [Parameter(Mandatory = $false)]
  [string]$ScratchDirectory = '',

  [Parameter(Mandatory = $false)]
  [switch]$KeepScratch
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Gh {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments,

    [Parameter(Mandatory = $false)]
    [switch]$AllowFailure
  )

  $output = & gh @Arguments 2>&1
  $exitCode = $LASTEXITCODE
  $text = (@($output) -join [Environment]::NewLine).Trim()
  if ($exitCode -ne 0 -and -not $AllowFailure) {
    throw "gh command failed (exit $exitCode): gh $($Arguments -join ' ')`n$text"
  }

  [pscustomobject]@{
    ExitCode = [int]$exitCode
    OutputText = [string]$text
  }
}

function Resolve-OwnerRepo {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Candidate
  )

  if (-not [string]::IsNullOrWhiteSpace($Candidate)) {
    return $Candidate.Trim()
  }

  if (-not [string]::IsNullOrWhiteSpace([string]$env:GITHUB_REPOSITORY)) {
    return ([string]$env:GITHUB_REPOSITORY).Trim()
  }

  $repoView = Invoke-Gh -Arguments @('repo', 'view', '--json', 'nameWithOwner', '--jq', '.nameWithOwner')
  $nameWithOwner = $repoView.OutputText.Trim()
  if ([string]::IsNullOrWhiteSpace($nameWithOwner)) {
    throw "Unable to resolve owner/repo. Provide -OwnerRepo or set GITHUB_REPOSITORY."
  }
  return $nameWithOwner
}

function ConvertTo-BoolOrDefault {
  param(
    [Parameter(Mandatory = $false)]
    [object]$Value,
    [Parameter(Mandatory = $true)]
    [bool]$DefaultValue
  )

  if ($null -eq $Value) {
    return $DefaultValue
  }

  $text = [string]$Value
  if ([string]::IsNullOrWhiteSpace($text)) {
    return $DefaultValue
  }

  switch ($text.Trim().ToLowerInvariant()) {
    '1' { return $true }
    'true' { return $true }
    'yes' { return $true }
    'y' { return $true }
    'on' { return $true }
    '0' { return $false }
    'false' { return $false }
    'no' { return $false }
    'n' { return $false }
    'off' { return $false }
    default { return $DefaultValue }
  }
}

function ConvertTo-NonNegativeIntOrNull {
  param(
    [Parameter(Mandatory = $false)]
    [object]$Value
  )

  if ($null -eq $Value) {
    return $null
  }

  $text = [string]$Value
  if ([string]::IsNullOrWhiteSpace($text)) {
    return $null
  }

  [int]$parsed = 0
  if ([int]::TryParse($text.Trim(), [ref]$parsed) -and $parsed -ge 0) {
    return $parsed
  }
  return $null
}

function Get-FirstArtifactByPrefix {
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$Artifacts,
    [Parameter(Mandatory = $true)]
    [string]$Prefix
  )

  foreach ($artifact in $Artifacts) {
    $name = [string]$artifact.name
    if ($name.StartsWith($Prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      return $name
    }
  }

  return ''
}

$repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
$greenRunSchemaPath = Join-Path $repoRoot 'schemas/control-plane-green-run.schema.json'
$shadowEvaluationScriptPath = Join-Path $repoRoot 'scripts/Invoke-ShadowPromotionEvaluation.ps1'

if (-not (Test-Path -LiteralPath $greenRunSchemaPath -PathType Leaf)) {
  throw "Green-run schema not found: $greenRunSchemaPath"
}
if (-not (Test-Path -LiteralPath $shadowEvaluationScriptPath -PathType Leaf)) {
  throw "Shadow promotion evaluation script not found: $shadowEvaluationScriptPath"
}
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  throw "GitHub CLI (gh) is required on PATH."
}

if ([string]::IsNullOrWhiteSpace($MetricsDirectory)) {
  $MetricsDirectory = Join-Path $repoRoot 'artifacts/shadow-promotion-gate/metrics'
}
if ([string]::IsNullOrWhiteSpace($StateOutputPath)) {
  $StateOutputPath = Join-Path (Join-Path $repoRoot 'artifacts/shadow-promotion-gate') 'shadow-promotion-state.json'
}
if ([string]::IsNullOrWhiteSpace($ScratchDirectory)) {
  $ScratchDirectory = Join-Path (Join-Path $repoRoot 'artifacts/shadow-promotion-gate') 'downloads'
}

$resolvedOwnerRepo = Resolve-OwnerRepo -Candidate $OwnerRepo
$resolvedBranch = if ([string]::IsNullOrWhiteSpace($Branch)) { 'main' } else { $Branch.Trim() }
$escapedBranch = [System.Uri]::EscapeDataString($resolvedBranch)
$escapedWorkflowFile = [System.Uri]::EscapeDataString($WorkflowFile.Trim())

$metricsParent = Split-Path -Path $MetricsDirectory -Parent
if (-not [string]::IsNullOrWhiteSpace($metricsParent) -and -not (Test-Path -LiteralPath $metricsParent -PathType Container)) {
  New-Item -Path $metricsParent -ItemType Directory -Force | Out-Null
}
if (Test-Path -LiteralPath $MetricsDirectory -PathType Container) {
  Get-ChildItem -Path $MetricsDirectory -Filter 'green-run-*.json' -File | Remove-Item -Force
} else {
  New-Item -Path $MetricsDirectory -ItemType Directory -Force | Out-Null
}

$stateParent = Split-Path -Path $StateOutputPath -Parent
if (-not [string]::IsNullOrWhiteSpace($stateParent) -and -not (Test-Path -LiteralPath $stateParent -PathType Container)) {
  New-Item -Path $stateParent -ItemType Directory -Force | Out-Null
}

if (Test-Path -LiteralPath $ScratchDirectory -PathType Container) {
  Remove-Item -Path $ScratchDirectory -Recurse -Force
}
New-Item -Path $ScratchDirectory -ItemType Directory -Force | Out-Null

$defaultBranchResult = Invoke-Gh -Arguments @('api', "repos/$resolvedOwnerRepo", '--jq', '.default_branch')
$defaultBranch = $defaultBranchResult.OutputText.Trim()
if ([string]::IsNullOrWhiteSpace($defaultBranch)) {
  $defaultBranch = 'main'
}
if ($resolvedBranch -eq '<default>') {
  $resolvedBranch = $defaultBranch
  $escapedBranch = [System.Uri]::EscapeDataString($resolvedBranch)
}

$latestHeadShaResult = Invoke-Gh -Arguments @('api', "repos/$resolvedOwnerRepo/commits/$escapedBranch", '--jq', '.sha')
$latestHeadSha = $latestHeadShaResult.OutputText.Trim().ToLowerInvariant()
if ($latestHeadSha -notmatch '^[0-9a-f]{40}$') {
  throw "Resolved latest head SHA '$latestHeadSha' is invalid for '$resolvedOwnerRepo@$resolvedBranch'."
}

$runsResult = Invoke-Gh -Arguments @('api', "repos/$resolvedOwnerRepo/actions/workflows/$escapedWorkflowFile/runs?branch=$escapedBranch&status=completed&per_page=$MaxRunsToScan")
try {
  $runsPayload = $runsResult.OutputText | ConvertFrom-Json -ErrorAction Stop
}
catch {
  throw "Unable to parse workflow-runs payload for '$resolvedOwnerRepo/$WorkflowFile'."
}

$runs = @($runsPayload.workflow_runs)
$normalizedCount = 0

foreach ($run in $runs) {
  $runId = [int64]$run.id
  if ($runId -le 0) {
    continue
  }

  $artifactsResult = Invoke-Gh -Arguments @('api', "repos/$resolvedOwnerRepo/actions/runs/$runId/artifacts?per_page=100") -AllowFailure
  if ($artifactsResult.ExitCode -ne 0) {
    Write-Warning "Skipping run $runId; unable to list artifacts."
    continue
  }

  try {
    $artifactsPayload = $artifactsResult.OutputText | ConvertFrom-Json -ErrorAction Stop
  }
  catch {
    Write-Warning "Skipping run $runId; artifacts payload was invalid JSON."
    continue
  }

  $artifactName = Get-FirstArtifactByPrefix -Artifacts @($artifactsPayload.artifacts) -Prefix $ShadowDiagnosticsArtifactPrefix
  if ([string]::IsNullOrWhiteSpace($artifactName)) {
    continue
  }

  $runScratch = Join-Path $ScratchDirectory ("run-{0}" -f $runId)
  if (Test-Path -LiteralPath $runScratch -PathType Container) {
    Remove-Item -Path $runScratch -Recurse -Force
  }
  New-Item -Path $runScratch -ItemType Directory -Force | Out-Null

  $downloadResult = Invoke-Gh -Arguments @('run', 'download', "$runId", '--repo', $resolvedOwnerRepo, '--name', $artifactName, '--dir', $runScratch) -AllowFailure
  if ($downloadResult.ExitCode -ne 0) {
    Write-Warning "Skipping run $runId; unable to download artifact '$artifactName'."
    continue
  }

  $metricsFile = Get-ChildItem -Path $runScratch -File -Recurse | Where-Object { $_.Name -like '*.metrics.json' } | Sort-Object FullName | Select-Object -First 1
  if ($null -eq $metricsFile) {
    Write-Warning "Skipping run $runId; no *.metrics.json found in '$artifactName'."
    continue
  }

  try {
    $metrics = Get-Content -LiteralPath $metricsFile.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
  }
  catch {
    Write-Warning "Skipping run $runId; metrics file '$($metricsFile.FullName)' is invalid JSON."
    continue
  }

  $headSha = ([string]$run.head_sha).Trim().ToLowerInvariant()
  if ($headSha -notmatch '^[0-9a-f]{40}$') {
    Write-Warning "Skipping run $runId; head SHA '$headSha' is invalid."
    continue
  }

  $runStatus = [string]$run.status
  if ([string]::IsNullOrWhiteSpace($runStatus)) {
    $runStatus = 'completed'
  }
  $runConclusion = [string]$run.conclusion
  if ([string]::IsNullOrWhiteSpace($runConclusion)) {
    $runConclusion = 'unknown'
  }

  $runIsGreen = ($runStatus -eq 'completed' -and $runConclusion -eq 'success')
  $generatedUtc = [string]$metrics.generated_utc
  if ([string]::IsNullOrWhiteSpace($generatedUtc)) {
    $generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
  }

  $artifactContractHashes = @()
  foreach ($artifact in @($metrics.artifact_contract_hashes)) {
    if ($null -eq $artifact) {
      continue
    }
    $artifactNameValue = [string]$artifact.name
    if ([string]::IsNullOrWhiteSpace($artifactNameValue)) {
      continue
    }

    $artifactContractHashes += [pscustomobject]@{
      name = $artifactNameValue
      id = ConvertTo-NonNegativeIntOrNull -Value $artifact.id
      size_in_bytes = ConvertTo-NonNegativeIntOrNull -Value $artifact.size_in_bytes
    }
  }

  $runAttempt = if ($null -eq $run.run_attempt) { 1 } else { [int]$run.run_attempt }
  if ($runAttempt -lt 1) {
    $runAttempt = 1
  }

  $normalizedPayload = [ordered]@{
    schema_version = '1.0'
    generated_utc = $generatedUtc
    owner_repo = $resolvedOwnerRepo
    workflow = if ([string]::IsNullOrWhiteSpace([string]$metrics.workflow)) { [string]$run.name } else { [string]$metrics.workflow }
    run_id = $runId
    run_attempt = $runAttempt
    run_url = if ([string]::IsNullOrWhiteSpace([string]$run.html_url)) { "https://github.com/$resolvedOwnerRepo/actions/runs/$runId" } else { [string]$run.html_url }
    head_sha = $headSha
    expected_head_sha = $latestHeadSha
    is_authoritative_latest_head = ($headSha -eq $latestHeadSha)
    status = $runStatus
    conclusion = $runConclusion
    gate_outcome = if ($runIsGreen) { 'go' } else { 'no-go' }
    required_lanes_passed = $runIsGreen
    shadow_passed = ConvertTo-BoolOrDefault -Value $metrics.shadow_passed -DefaultValue $runIsGreen
    queue_seconds = ConvertTo-NonNegativeIntOrNull -Value $metrics.queue_seconds
    duration_seconds = ConvertTo-NonNegativeIntOrNull -Value $metrics.duration_seconds
    lane_name = if ([string]::IsNullOrWhiteSpace([string]$metrics.lane_name)) { $ShadowLaneName } else { [string]$metrics.lane_name }
    lane_role = 'shadow'
    ppl_target_os = if ([string]::IsNullOrWhiteSpace([string]$metrics.ppl_target_os)) { $null } else { [string]$metrics.ppl_target_os }
    ppl_bitness = if ([string]::IsNullOrWhiteSpace([string]$metrics.ppl_bitness)) { $null } else { [string]$metrics.ppl_bitness }
    container_image = if ($null -eq $metrics.container_image -or [string]::IsNullOrWhiteSpace([string]$metrics.container_image)) { $null } else { [string]$metrics.container_image }
    rollout_signature = if ([string]::IsNullOrWhiteSpace([string]$metrics.rollout_signature)) { '' } else { [string]$metrics.rollout_signature }
    runner_pool_signature = if ([string]::IsNullOrWhiteSpace([string]$metrics.runner_pool_signature)) { '' } else { [string]$metrics.runner_pool_signature }
    artifact_contract_hashes = $artifactContractHashes
  }

  $normalizedJson = $normalizedPayload | ConvertTo-Json -Depth 12
  if (-not ($normalizedJson | Test-Json -SchemaFile $greenRunSchemaPath)) {
    Write-Warning "Skipping run $runId; normalized payload did not satisfy control-plane green-run schema."
    continue
  }

  $normalizedPath = Join-Path $MetricsDirectory ("green-run-{0}.json" -f $runId)
  Set-Content -LiteralPath $normalizedPath -Value $normalizedJson -Encoding utf8
  $normalizedCount += 1
}

& $shadowEvaluationScriptPath `
  -MetricsDirectory $MetricsDirectory `
  -MinConsecutiveGreens $MinConsecutiveGreens `
  -ShadowLaneNames @($ShadowLaneName) `
  -OutputPath $StateOutputPath

if (-not (Test-Path -LiteralPath $StateOutputPath -PathType Leaf)) {
  throw "Shadow promotion state was not generated at '$StateOutputPath'."
}

$statePayload = Get-Content -LiteralPath $StateOutputPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
$evaluatedRunIds = (@($statePayload.evaluated_runs | ForEach-Object { [string]$_.run_id }) -join ',')
if ([string]::IsNullOrWhiteSpace($evaluatedRunIds)) {
  $evaluatedRunIds = '<none>'
}

Write-Host "Collected $normalizedCount normalized shadow metrics for lane '$ShadowLaneName' from '$resolvedOwnerRepo@$resolvedBranch'."
Write-Host "Shadow promotion state: threshold=$($statePayload.threshold), consecutive_green_count=$($statePayload.consecutive_green_count), promotion_ready=$($statePayload.promotion_ready), reset_reason=$($statePayload.reset_reason), evaluated_run_ids=$evaluatedRunIds"
Write-Host "State payload path: $StateOutputPath"

if (-not $KeepScratch -and (Test-Path -LiteralPath $ScratchDirectory -PathType Container)) {
  Remove-Item -Path $ScratchDirectory -Recurse -Force
}

$statePayload
