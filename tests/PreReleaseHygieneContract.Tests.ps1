#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Pre-release hygiene contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path

        $script:activeRuntimeReleaseFiles = @(
            'README.md',
            'manifest.json',
            '.github/workflows/release-skill-layer.yml',
            'scripts/New-ReleasePayloadManifest.ps1',
            'tests/ManifestContract.Tests.ps1',
            'tests/ReleaseWorkflowContract.Tests.ps1',
            'tests/ReleasePayloadManifestContract.Tests.ps1'
        )

        $script:governedExecutionPolicyFiles = @(
            @((Get-ChildItem -Path (Join-Path $script:repoRoot '.github/workflows') -Filter '*.yml' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })),
            @((Get-ChildItem -Path (Join-Path $script:repoRoot 'docs/agents') -Filter '*.md' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })),
            @((Get-ChildItem -Path (Join-Path $script:repoRoot 'scripts') -Filter '*.ps1' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })),
            @((Get-ChildItem -Path (Join-Path $script:repoRoot 'tests') -Filter '*.ps1' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })),
            (Join-Path $script:repoRoot 'README.md')
        ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Sort-Object -Unique
    }

    It 'has no stale proactive-loop marker in active runtime/release files' {
        foreach ($relativePath in $script:activeRuntimeReleaseFiles) {
            $fullPath = Join-Path $script:repoRoot $relativePath
            if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
                continue
            }

            $content = Get-Content -LiteralPath $fullPath -Raw
            $content | Should -Not -Match ([regex]::Escape('proactive-loop')) -Because "stale module marker must not appear in '$relativePath'"
        }
    }

    It 'has no stale v0.4.1 marker in active runtime/release files' {
        foreach ($relativePath in $script:activeRuntimeReleaseFiles) {
            $fullPath = Join-Path $script:repoRoot $relativePath
            if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
                continue
            }

            $content = Get-Content -LiteralPath $fullPath -Raw
            $content | Should -Not -Match ([regex]::Escape('v0.4.1')) -Because "stale version marker must not appear in '$relativePath'"
        }
    }

    It 'contains no forbidden execution-policy literal in governed paths' {
        $policyToken = 'ExecutionPolicy'
        $blockedPolicyValue = ('By' + 'pass')
        $forbiddenPattern = [regex]::Escape($policyToken) + '\s+' + [regex]::Escape($blockedPolicyValue)

        foreach ($fullPath in $script:governedExecutionPolicyFiles) {
            $content = Get-Content -LiteralPath $fullPath -Raw
            $relativePath = [System.IO.Path]::GetRelativePath($script:repoRoot, $fullPath).Replace('\', '/')
            $content | Should -Not -Match $forbiddenPattern -Because "forbidden execution-policy literal must not appear in '$relativePath'"
        }
    }
}
