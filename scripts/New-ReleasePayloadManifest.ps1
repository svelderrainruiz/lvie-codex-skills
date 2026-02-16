#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ReleaseTag,

    [Parameter(Mandatory = $true)]
    [string]$StageDirectory,

    [Parameter(Mandatory = $true)]
    [string]$SourceProjectRepo,

    [Parameter(Mandatory = $true)]
    [string]$SourceProjectRef,

    [Parameter(Mandatory = $true)]
    [string]$SourceProjectSha,

    [Parameter(Mandatory = $true)]
    [string]$CiRepository,

    [Parameter(Mandatory = $true)]
    [string]$CiRunId,

    [Parameter(Mandatory = $true)]
    [string]$CiRunAttempt,

    [Parameter(Mandatory = $true)]
    [string]$CiRunUrl,

    [string]$OutputPath = 'release-payload-manifest.json',

    [string]$LaneMatrixPath = 'contracts/build-lane-matrix.json',

    [string]$SchemaPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-FullPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path -Path (Get-Location).Path -ChildPath $Path))
}

function Ensure-Directory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

$resolvedStageDirectory = Resolve-FullPath -Path $StageDirectory
if (-not (Test-Path -LiteralPath $resolvedStageDirectory -PathType Container)) {
    throw "StageDirectory not found: $resolvedStageDirectory"
}

$resolvedOutputPath = if ([System.IO.Path]::IsPathRooted($OutputPath)) {
    Resolve-FullPath -Path $OutputPath
}
else {
    Resolve-FullPath -Path (Join-Path -Path $resolvedStageDirectory -ChildPath $OutputPath)
}

$scriptRepoRoot = Resolve-FullPath -Path (Join-Path -Path $PSScriptRoot -ChildPath '..')
$resolvedLaneMatrixPath = if ([System.IO.Path]::IsPathRooted($LaneMatrixPath)) {
    Resolve-FullPath -Path $LaneMatrixPath
}
else {
    Resolve-FullPath -Path (Join-Path -Path $scriptRepoRoot -ChildPath $LaneMatrixPath)
}

if (-not (Test-Path -LiteralPath $resolvedLaneMatrixPath -PathType Leaf)) {
    throw "Lane matrix contract not found: $resolvedLaneMatrixPath"
}

$laneMatrixSchemaPath = Resolve-FullPath -Path (Join-Path -Path $scriptRepoRoot -ChildPath 'schemas/build-lane-matrix.schema.json')
if (-not (Test-Path -LiteralPath $laneMatrixSchemaPath -PathType Leaf)) {
    throw "Lane matrix schema not found: $laneMatrixSchemaPath"
}

$laneMatrixJson = Get-Content -LiteralPath $resolvedLaneMatrixPath -Raw
$laneMatrixIsValid = $laneMatrixJson | Test-Json -SchemaFile $laneMatrixSchemaPath -ErrorAction Stop
if (-not $laneMatrixIsValid) {
    throw "Lane matrix contract failed schema validation: $resolvedLaneMatrixPath"
}

$laneMatrix = $laneMatrixJson | ConvertFrom-Json -ErrorAction Stop
$requiredLaneAssets = @()
$optionalLaneAssets = @()
foreach ($lane in @($laneMatrix.lanes)) {
    if ($null -eq $lane) {
        continue
    }

    $includeInRelease = $false
    if ($null -ne $lane.include_in_release_payload) {
        $includeInRelease = [bool]$lane.include_in_release_payload
    }
    if (-not $includeInRelease) {
        continue
    }

    $releaseAssetName = [string]$lane.release_asset_name
    $releaseAssetCategory = [string]$lane.release_asset_category
    if ([string]::IsNullOrWhiteSpace($releaseAssetName)) {
        throw "Lane '$($lane.lane_id)' has include_in_release_payload=true but release_asset_name is empty."
    }
    if ([string]::IsNullOrWhiteSpace($releaseAssetCategory)) {
        throw "Lane '$($lane.lane_id)' has include_in_release_payload=true but release_asset_category is empty."
    }

    $laneAsset = @{
        name = $releaseAssetName.Trim()
        category = $releaseAssetCategory.Trim()
    }

    $laneIsRequired = $false
    if ($null -ne $lane.required) {
        $laneIsRequired = [bool]$lane.required
    }
    elseif ([string]::Equals([string]$lane.role, 'required', [System.StringComparison]::OrdinalIgnoreCase)) {
        $laneIsRequired = $true
    }

    if ($laneIsRequired) {
        $requiredLaneAssets += $laneAsset
    }
    else {
        $optionalLaneAssets += $laneAsset
    }
}

$requiredAssets = @(
    @{ name = 'lvie-codex-skill-layer-installer.exe'; category = 'installer' }
)
$requiredAssets += $requiredLaneAssets
$requiredAssets += @(
    @{ name = 'lvie-vip-package-self-hosted.zip'; category = 'vip_package_self_hosted' },
    @{ name = 'release-provenance.json'; category = 'provenance' }
)

$dedupedRequiredAssets = @{}
foreach ($requiredAsset in $requiredAssets) {
    $assetName = [string]$requiredAsset.name
    if ([string]::IsNullOrWhiteSpace($assetName)) {
        throw "Required asset contract contains an empty asset name."
    }
    $dedupedRequiredAssets[$assetName] = @{
        name = $assetName
        category = [string]$requiredAsset.category
    }
}
$requiredAssets = @($dedupedRequiredAssets.Values)

$dedupedOptionalAssets = @{}
foreach ($optionalAsset in $optionalLaneAssets) {
    $assetName = [string]$optionalAsset.name
    if ([string]::IsNullOrWhiteSpace($assetName)) {
        throw "Optional asset contract contains an empty asset name."
    }

    if ($dedupedRequiredAssets.ContainsKey($assetName)) {
        continue
    }

    $dedupedOptionalAssets[$assetName] = @{
        name = $assetName
        category = [string]$optionalAsset.category
    }
}
$optionalAssets = @($dedupedOptionalAssets.Values)

$assetRecords = @()
foreach ($requiredAsset in $requiredAssets) {
    $assetPath = Join-Path -Path $resolvedStageDirectory -ChildPath $requiredAsset.name
    if (-not (Test-Path -LiteralPath $assetPath -PathType Leaf)) {
        throw "Required staged release asset missing: $assetPath"
    }

    $assetItem = Get-Item -LiteralPath $assetPath
    $assetHash = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $assetRecords += [pscustomobject]@{
        name = $requiredAsset.name
        sha256 = $assetHash
        size_bytes = [int64]$assetItem.Length
        category = $requiredAsset.category
    }
}

foreach ($optionalAsset in $optionalAssets) {
    $assetPath = Join-Path -Path $resolvedStageDirectory -ChildPath $optionalAsset.name
    if (-not (Test-Path -LiteralPath $assetPath -PathType Leaf)) {
        continue
    }

    $assetItem = Get-Item -LiteralPath $assetPath
    $assetHash = (Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $assetRecords += [pscustomobject]@{
        name = $optionalAsset.name
        sha256 = $assetHash
        size_bytes = [int64]$assetItem.Length
        category = $optionalAsset.category
    }
}

$manifest = [pscustomobject]@{
    schema_version = '1.0'
    generated_utc = (Get-Date).ToUniversalTime().ToString('o')
    release_tag = $ReleaseTag
    source_project = [pscustomobject]@{
        repo = $SourceProjectRepo
        ref = $SourceProjectRef
        sha = $SourceProjectSha
    }
    skills_ci_run = [pscustomobject]@{
        repository = $CiRepository
        run_id = $CiRunId
        run_attempt = $CiRunAttempt
        run_url = $CiRunUrl
    }
    assets = @($assetRecords)
}

$manifestJson = $manifest | ConvertTo-Json -Depth 10

if (-not [string]::IsNullOrWhiteSpace($SchemaPath)) {
    $resolvedSchemaPath = Resolve-FullPath -Path $SchemaPath
    if (-not (Test-Path -LiteralPath $resolvedSchemaPath -PathType Leaf)) {
        throw "SchemaPath not found: $resolvedSchemaPath"
    }

    $isValid = $manifestJson | Test-Json -SchemaFile $resolvedSchemaPath -ErrorAction Stop
    if (-not $isValid) {
        throw "Generated release payload manifest did not pass schema validation: $resolvedSchemaPath"
    }
}

$outputDirectory = Split-Path -Path $resolvedOutputPath -Parent
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
    Ensure-Directory -Path $outputDirectory
}

Set-Content -LiteralPath $resolvedOutputPath -Value $manifestJson -Encoding UTF8
Write-Host "Release payload manifest: $resolvedOutputPath"
