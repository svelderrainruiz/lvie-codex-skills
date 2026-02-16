#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Release payload manifest contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:schemaPath = Join-Path $script:repoRoot 'schemas/release-payload-contract.schema.json'
        $script:generatorPath = Join-Path $script:repoRoot 'scripts/New-ReleasePayloadManifest.ps1'
        $script:laneMatrixPath = Join-Path $script:repoRoot 'contracts/build-lane-matrix.json'
        $script:laneMatrixSchemaPath = Join-Path $script:repoRoot 'schemas/build-lane-matrix.schema.json'

        foreach ($path in @(
            $script:schemaPath,
            $script:generatorPath,
            $script:laneMatrixPath,
            $script:laneMatrixSchemaPath
        )) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Required release payload contract file missing: $path"
            }
        }

        $script:schema = Get-Content -LiteralPath $script:schemaPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $script:laneMatrixJson = Get-Content -LiteralPath $script:laneMatrixPath -Raw
        $laneMatrixValid = $script:laneMatrixJson | Test-Json -SchemaFile $script:laneMatrixSchemaPath -ErrorAction Stop
        if (-not $laneMatrixValid) {
            throw "Lane matrix contract failed schema validation: $($script:laneMatrixPath)"
        }
        $script:laneMatrix = $script:laneMatrixJson | ConvertFrom-Json -ErrorAction Stop

        $script:requiredLaneReleaseAssets = @(
            foreach ($lane in @($script:laneMatrix.lanes)) {
                if ($null -eq $lane) {
                    continue
                }
                if ($null -eq $lane.include_in_release_payload -or -not [bool]$lane.include_in_release_payload) {
                    continue
                }
                $laneIsRequired = $false
                if ($null -ne $lane.required) {
                    $laneIsRequired = [bool]$lane.required
                }
                elseif (-not [string]::IsNullOrWhiteSpace([string]$lane.role)) {
                    $laneIsRequired = [string]::Equals([string]$lane.role, 'required', [System.StringComparison]::OrdinalIgnoreCase)
                }
                if (-not $laneIsRequired) {
                    continue
                }

                [pscustomobject]@{
                    name = [string]$lane.release_asset_name
                    category = [string]$lane.release_asset_category
                }
            }
        )
        $script:optionalLaneReleaseAssets = @(
            foreach ($lane in @($script:laneMatrix.lanes)) {
                if ($null -eq $lane) {
                    continue
                }
                if ($null -eq $lane.include_in_release_payload -or -not [bool]$lane.include_in_release_payload) {
                    continue
                }
                $laneIsRequired = $false
                if ($null -ne $lane.required) {
                    $laneIsRequired = [bool]$lane.required
                }
                elseif (-not [string]::IsNullOrWhiteSpace([string]$lane.role)) {
                    $laneIsRequired = [string]::Equals([string]$lane.role, 'required', [System.StringComparison]::OrdinalIgnoreCase)
                }
                if ($laneIsRequired) {
                    continue
                }

                [pscustomobject]@{
                    name = [string]$lane.release_asset_name
                    category = [string]$lane.release_asset_category
                }
            }
        )
        $script:staticRequiredReleaseAssets = @(
            [pscustomobject]@{ name = 'lvie-codex-skill-layer-installer.exe'; category = 'installer' },
            [pscustomobject]@{ name = 'lvie-vip-package-self-hosted.zip'; category = 'vip_package_self_hosted' },
            [pscustomobject]@{ name = 'release-provenance.json'; category = 'provenance' }
        )
        $script:requiredExpectedAssets = @($script:requiredLaneReleaseAssets + $script:staticRequiredReleaseAssets)
        $script:requiredExpectedAssetNames = @($script:requiredExpectedAssets.name | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        $script:requiredExpectedCategories = @($script:requiredExpectedAssets.category | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        $script:optionalExpectedAssetNames = @($script:optionalLaneReleaseAssets.name | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        $script:optionalExpectedCategories = @($script:optionalLaneReleaseAssets.category | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        $script:allExpectedAssetNames = @($script:requiredExpectedAssetNames + $script:optionalExpectedAssetNames | Select-Object -Unique)
        $script:allExpectedCategories = @($script:requiredExpectedCategories + $script:optionalExpectedCategories | Select-Object -Unique)
    }

    It 'defines required top-level fields and category enum in schema' {
        @($script:schema.required) | Should -Contain 'schema_version'
        @($script:schema.required) | Should -Contain 'generated_utc'
        @($script:schema.required) | Should -Contain 'release_tag'
        @($script:schema.required) | Should -Contain 'source_project'
        @($script:schema.required) | Should -Contain 'skills_ci_run'
        @($script:schema.required) | Should -Contain 'assets'
        [bool]$script:schema.additionalProperties | Should -BeFalse

        $categories = @($script:schema.properties.assets.items.properties.category.enum)
        foreach ($category in $script:allExpectedCategories) {
            $categories | Should -Contain $category
        }
    }

    It 'generates a schema-valid release payload manifest with lane-matrix-required assets' {
        $tempRoot = Join-Path $env:TEMP ("release-payload-manifest-{0}" -f [guid]::NewGuid().ToString('N'))
        New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
        try {
            foreach ($name in $script:allExpectedAssetNames) {
                $path = Join-Path $tempRoot $name
                Set-Content -LiteralPath $path -Value "fixture-$name" -Encoding UTF8
            }

            & $script:generatorPath `
                -ReleaseTag 'v0.1.0' `
                -StageDirectory $tempRoot `
                -SourceProjectRepo 'svelderrainruiz/labview-icon-editor' `
                -SourceProjectRef 'main' `
                -SourceProjectSha '1234567890abcdef1234567890abcdef12345678' `
                -CiRepository 'svelderrainruiz/lvie-codex-skills' `
                -CiRunId '100' `
                -CiRunAttempt '1' `
                -CiRunUrl 'https://github.com/svelderrainruiz/lvie-codex-skills/actions/runs/100' `
                -OutputPath (Join-Path $tempRoot 'release-payload-manifest.json') `
                -LaneMatrixPath $script:laneMatrixPath `
                -SchemaPath $script:schemaPath

            $manifestPath = Join-Path $tempRoot 'release-payload-manifest.json'
            Test-Path -LiteralPath $manifestPath -PathType Leaf | Should -BeTrue

            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
            [string]$manifest.schema_version | Should -Be '1.0'
            [string]$manifest.release_tag | Should -Be 'v0.1.0'
            @($manifest.assets).Count | Should -Be $script:allExpectedAssetNames.Count
            foreach ($category in $script:allExpectedCategories) {
                @($manifest.assets.category) | Should -Contain $category
            }
            foreach ($name in $script:allExpectedAssetNames) {
                @($manifest.assets.name) | Should -Contain $name
            }
            foreach ($asset in @($manifest.assets)) {
                [string]$asset.sha256 | Should -Match '^[a-f0-9]{64}$'
                [int64]$asset.size_bytes | Should -BeGreaterOrEqual 0
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'fails when a lane-matrix-required staged release asset is missing' {
        $tempRoot = Join-Path $env:TEMP ("release-payload-missing-{0}" -f [guid]::NewGuid().ToString('N'))
        New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
        try {
            $missingName = [string]$script:requiredLaneReleaseAssets[0].name
            foreach ($name in $script:allExpectedAssetNames) {
                if ($name -eq $missingName) {
                    continue
                }
                $path = Join-Path $tempRoot $name
                Set-Content -LiteralPath $path -Value "fixture-$name" -Encoding UTF8
            }

            $failed = $false
            $errorMessage = ''
            try {
                & $script:generatorPath `
                    -ReleaseTag 'v0.1.0' `
                    -StageDirectory $tempRoot `
                    -SourceProjectRepo 'svelderrainruiz/labview-icon-editor' `
                    -SourceProjectRef 'main' `
                    -SourceProjectSha '1234567890abcdef1234567890abcdef12345678' `
                    -CiRepository 'svelderrainruiz/lvie-codex-skills' `
                    -CiRunId '100' `
                    -CiRunAttempt '1' `
                    -CiRunUrl 'https://github.com/svelderrainruiz/lvie-codex-skills/actions/runs/100' `
                    -LaneMatrixPath $script:laneMatrixPath `
                    -SchemaPath $script:schemaPath
            }
            catch {
                $failed = $true
                $errorMessage = $_.Exception.Message
            }

            $failed | Should -BeTrue
            $errorMessage | Should -Match 'Required staged release asset missing'
            $errorMessage | Should -Match ([regex]::Escape($missingName))
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }

    It 'allows missing optional shadow lane assets while keeping required assets schema-valid' {
        $tempRoot = Join-Path $env:TEMP ("release-payload-optional-{0}" -f [guid]::NewGuid().ToString('N'))
        New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
        try {
            foreach ($name in $script:requiredExpectedAssetNames) {
                $path = Join-Path $tempRoot $name
                Set-Content -LiteralPath $path -Value "fixture-$name" -Encoding UTF8
            }

            & $script:generatorPath `
                -ReleaseTag 'v0.1.0' `
                -StageDirectory $tempRoot `
                -SourceProjectRepo 'svelderrainruiz/labview-icon-editor' `
                -SourceProjectRef 'main' `
                -SourceProjectSha '1234567890abcdef1234567890abcdef12345678' `
                -CiRepository 'svelderrainruiz/lvie-codex-skills' `
                -CiRunId '100' `
                -CiRunAttempt '1' `
                -CiRunUrl 'https://github.com/svelderrainruiz/lvie-codex-skills/actions/runs/100' `
                -OutputPath (Join-Path $tempRoot 'release-payload-manifest.json') `
                -LaneMatrixPath $script:laneMatrixPath `
                -SchemaPath $script:schemaPath

            $manifestPath = Join-Path $tempRoot 'release-payload-manifest.json'
            Test-Path -LiteralPath $manifestPath -PathType Leaf | Should -BeTrue

            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
            @($manifest.assets).Count | Should -Be $script:requiredExpectedAssetNames.Count
            foreach ($name in $script:requiredExpectedAssetNames) {
                @($manifest.assets.name) | Should -Contain $name
            }
            foreach ($name in $script:optionalExpectedAssetNames) {
                @($manifest.assets.name) | Should -Not -Contain $name
            }
        }
        finally {
            if (Test-Path -LiteralPath $tempRoot -PathType Container) {
                Remove-Item -LiteralPath $tempRoot -Recurse -Force
            }
        }
    }
}
