#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SkillsRepo,

    [Parameter(Mandatory = $false)]
    [string]$SourceProjectRepo = '',

    [Parameter(Mandatory = $false)]
    [string]$SourceProjectRef = '',

    [Parameter(Mandatory = $false)]
    [string]$LabviewProfile = 'lv2026',

    [Parameter(Mandatory = $false)]
    [ValidateSet('auto', 'strict', 'container-only')]
    [string]$ParityEnforcementProfile = 'auto',

    [Parameter(Mandatory = $false)]
    [switch]$RefreshSourceSha,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepoId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repository
    )

    $trimmed = $Repository.Trim()
    if ($trimmed -match '^(?<repo>[^/\s]+/[^/\s]+)$') {
        return [string]$Matches.repo
    }

    if ($trimmed -match '^https://github\.com/(?<repo>[^/]+/[^/.]+?)(?:\.git)?/?$') {
        return [string]$Matches.repo
    }

    throw "Repository '$Repository' is invalid. Expected '<owner>/<repo>' or 'https://github.com/<owner>/<repo>.git'."
}

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
        OutputText = $text
    }
}

function Get-RepositoryVariableValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repository,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $result = Invoke-Gh -Arguments @('api', "repos/$Repository/actions/variables/$Name") -AllowFailure
    if ($result.ExitCode -ne 0) {
        return ''
    }

    try {
        $payload = $result.OutputText | ConvertFrom-Json -ErrorAction Stop
        return [string]$payload.value
    }
    catch {
        throw "Unable to parse repository variable '$Name' response for '$Repository'."
    }
}

function Set-RepositoryVariable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repository,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $probe = Invoke-Gh -Arguments @('api', "repos/$Repository/actions/variables/$Name") -AllowFailure
    if ($probe.ExitCode -eq 0) {
        Invoke-Gh -Arguments @(
            'api',
            '-X', 'PATCH',
            "repos/$Repository/actions/variables/$Name",
            '-f', "name=$Name",
            '-f', "value=$Value"
        ) | Out-Null
        return 'updated'
    }

    Invoke-Gh -Arguments @(
        'api',
        '-X', 'POST',
        "repos/$Repository/actions/variables",
        '-f', "name=$Name",
        '-f', "value=$Value"
    ) | Out-Null
    return 'created'
}

function Remove-RepositoryVariable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repository,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $probe = Invoke-Gh -Arguments @('api', "repos/$Repository/actions/variables/$Name") -AllowFailure
    if ($probe.ExitCode -ne 0) {
        return 'absent'
    }

    Invoke-Gh -Arguments @(
        'api',
        '-X', 'DELETE',
        "repos/$Repository/actions/variables/$Name"
    ) | Out-Null
    return 'removed'
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
    $OutputPath = Join-Path $repoRoot 'artifacts/portability-bootstrap/portability-bootstrap.result.json'
}

$outputDirectory = Split-Path -Path $OutputPath -Parent
if (-not [string]::IsNullOrWhiteSpace($outputDirectory) -and -not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
}

$result = [ordered]@{
    schema_version = '1.0'
    generated_utc = (Get-Date).ToUniversalTime().ToString('o')
    status = 'failed'
    skills_repo = ''
    source_project_repo = ''
    source_project_ref = ''
    source_project_sha = ''
    refresh_source_sha = [bool]$RefreshSourceSha
    labview_profile = [string]$LabviewProfile
    parity_enforcement_profile = [string]$ParityEnforcementProfile
    variable_updates = @()
    error = ''
}

try {
    $ghProbe = Invoke-Gh -Arguments @('--version') -AllowFailure
    if ($ghProbe.ExitCode -ne 0) {
        throw "GitHub CLI (gh) is required on PATH."
    }

    $authProbe = Invoke-Gh -Arguments @('auth', 'status') -AllowFailure
    if ($authProbe.ExitCode -ne 0) {
        throw "GitHub CLI is not authenticated. Run 'gh auth login' first."
    }

    $skillsRepoId = Resolve-RepoId -Repository $SkillsRepo
    $result.skills_repo = $skillsRepoId

    $existingSourceRepo = Get-RepositoryVariableValue -Repository $skillsRepoId -Name 'LVIE_SOURCE_PROJECT_REPO'
    $existingSourceRef = Get-RepositoryVariableValue -Repository $skillsRepoId -Name 'LVIE_SOURCE_PROJECT_REF'
    $defaultSourceRepo = "{0}/labview-icon-editor" -f ($skillsRepoId.Split('/')[0])

    if ([string]::IsNullOrWhiteSpace($SourceProjectRepo)) {
        if ($RefreshSourceSha -and -not [string]::IsNullOrWhiteSpace($existingSourceRepo)) {
            $SourceProjectRepo = $existingSourceRepo
        } elseif (-not [string]::IsNullOrWhiteSpace($existingSourceRepo)) {
            $SourceProjectRepo = $existingSourceRepo
        } else {
            $SourceProjectRepo = $defaultSourceRepo
        }
    }

    if ([string]::IsNullOrWhiteSpace($SourceProjectRef)) {
        if ($RefreshSourceSha -and -not [string]::IsNullOrWhiteSpace($existingSourceRef)) {
            $SourceProjectRef = $existingSourceRef
        } elseif (-not [string]::IsNullOrWhiteSpace($existingSourceRef)) {
            $SourceProjectRef = $existingSourceRef
        } else {
            $SourceProjectRef = 'main'
        }
    }

    $sourceProjectRepoId = Resolve-RepoId -Repository $SourceProjectRepo
    $sourceProjectRefValue = $SourceProjectRef.Trim()
    if ([string]::IsNullOrWhiteSpace($sourceProjectRefValue)) {
        throw "SourceProjectRef cannot be empty."
    }

    $result.source_project_repo = $sourceProjectRepoId
    $result.source_project_ref = $sourceProjectRefValue

    $resolvedSha = ''
    if ($RefreshSourceSha) {
        $encodedRef = [System.Uri]::EscapeDataString($sourceProjectRefValue)
        $commitResult = Invoke-Gh -Arguments @('api', "repos/$sourceProjectRepoId/commits/$encodedRef", '--jq', '.sha')
        $resolvedSha = $commitResult.OutputText.Trim().ToLowerInvariant()
        if ($resolvedSha -notmatch '^[0-9a-f]{40}$') {
            throw "Resolved source SHA '$resolvedSha' is invalid for '$sourceProjectRepoId@$sourceProjectRefValue'."
        }
        $result.source_project_sha = $resolvedSha
    }

    $resolvedLabviewProfile = if ([string]::IsNullOrWhiteSpace($LabviewProfile)) { 'lv2026' } else { $LabviewProfile.Trim() }
    $resolvedParityProfile = if ([string]::IsNullOrWhiteSpace($ParityEnforcementProfile)) { 'auto' } else { $ParityEnforcementProfile.Trim().ToLowerInvariant() }
    $result.labview_profile = $resolvedLabviewProfile
    $result.parity_enforcement_profile = $resolvedParityProfile

    $variablesToSet = [ordered]@{
        LVIE_SOURCE_PROJECT_REPO = $sourceProjectRepoId
        LVIE_SOURCE_PROJECT_REF = $sourceProjectRefValue
        LVIE_LABVIEW_PROFILE = $resolvedLabviewProfile
        LVIE_PARITY_ENFORCEMENT_PROFILE = $resolvedParityProfile
    }

    if ($RefreshSourceSha) {
        $variablesToSet['LVIE_SOURCE_PROJECT_SHA'] = $resolvedSha
    }

    foreach ($entry in $variablesToSet.GetEnumerator()) {
        $actionTaken = Set-RepositoryVariable -Repository $skillsRepoId -Name $entry.Key -Value ([string]$entry.Value)
        $result.variable_updates += [pscustomobject]@{
            name = [string]$entry.Key
            value = [string]$entry.Value
            action = [string]$actionTaken
        }
    }

    if (-not $RefreshSourceSha) {
        $actionTaken = Remove-RepositoryVariable -Repository $skillsRepoId -Name 'LVIE_SOURCE_PROJECT_SHA'
        $result.variable_updates += [pscustomobject]@{
            name = 'LVIE_SOURCE_PROJECT_SHA'
            value = ''
            action = [string]$actionTaken
        }
    }

    $result.status = 'success'
}
catch {
    $result.error = $_.Exception.Message
}

$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding utf8

if ($result.status -ne 'success') {
    throw "Fork portability bootstrap failed: $($result.error). See '$OutputPath'."
}

Write-Host "Fork portability bootstrap succeeded for '$($result.skills_repo)'."
if ($RefreshSourceSha) {
    Write-Host "Source pin: $($result.source_project_repo)@$($result.source_project_ref) -> $($result.source_project_sha)"
} else {
    Write-Host "Source pin mode: floating ref (LVIE_SOURCE_PROJECT_SHA removed unless explicitly refreshed)."
}
Write-Host "Result payload: $OutputPath"
