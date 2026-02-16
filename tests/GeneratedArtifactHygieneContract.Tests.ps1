#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Generated artifact hygiene contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:gitIgnorePath = Join-Path $script:repoRoot '.gitignore'
    }

    It 'defines ignore patterns for generated artifact noise roots' {
        if (-not (Test-Path -LiteralPath $script:gitIgnorePath -PathType Leaf)) {
            throw "Missing .gitignore at '$script:gitIgnorePath'."
        }

        $content = Get-Content -LiteralPath $script:gitIgnorePath -Raw

        $requiredPatterns = @(
            '/artifacts/**',
            '/worktmp/',
            '/worktrees/',
            '/consumer/',
            '/testResults.xml',
            '/TestResults/',
            '*.trx'
        )

        foreach ($pattern in $requiredPatterns) {
            $escaped = [regex]::Escape($pattern)
            $content | Should -Match "(?m)^$escaped\r?$" -Because ".gitignore must include '$pattern'"
        }
    }

    It 'does not track generated local workspace roots' {
        $tracked = @(& git -C $script:repoRoot ls-files)
        if ($LASTEXITCODE -ne 0) {
            throw "git ls-files failed with exit code $LASTEXITCODE."
        }

        $blockedRoots = @('consumer/', 'worktmp/', 'worktrees/')
        foreach ($root in $blockedRoots) {
            $matches = @($tracked | Where-Object { $_.StartsWith($root, [System.StringComparison]::Ordinal) })
            $matches.Count | Should -Be 0 -Because "tracked files under '$root' are generated workspace noise"
        }
    }

    It 'keeps tracked artifacts in allowlisted paths only' {
        $trackedArtifacts = @(& git -C $script:repoRoot ls-files artifacts)
        if ($LASTEXITCODE -ne 0) {
            throw "git ls-files artifacts failed with exit code $LASTEXITCODE."
        }

        $allowlistedTrackedArtifacts = @(
            'artifacts/release-metrics/release-metrics-22005219153.json',
            'artifacts/release-state/release-state-22005219153.json'
        )

        foreach ($artifactPath in $trackedArtifacts) {
            $allowlistedTrackedArtifacts | Should -Contain $artifactPath -Because "tracked artifact '$artifactPath' must be explicitly allowlisted"
        }
    }
}
