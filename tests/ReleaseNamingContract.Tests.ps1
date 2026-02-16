#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Release naming contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:governedPatterns = @(
            'README.md',
            '.github/workflows/*.yml',
            'docs/release-governance/*',
            'docs/agents/*.md',
            'tests/*.Tests.ps1',
            'control-plane-roadmap*.md'
        )

        $script:phaseTokenPattern = '(?i)(phase-?[1-4]|phase\s+[1-4])'
    }

    It 'does not include generic phase-number labels in governed paths' {
        $violations = New-Object System.Collections.Generic.List[string]

        foreach ($pattern in $script:governedPatterns) {
            $paths = Get-ChildItem -Path (Join-Path $script:repoRoot $pattern) -File -ErrorAction SilentlyContinue
            foreach ($path in $paths) {
                if ($path.Name -eq 'ReleaseNamingContract.Tests.ps1') {
                    continue
                }

                $lineNumber = 0
                foreach ($line in Get-Content -LiteralPath $path.FullName) {
                    $lineNumber++
                    if ($line -match $script:phaseTokenPattern) {
                        $violations.Add(('{0}:{1}: {2}' -f $path.FullName, $lineNumber, $line.Trim()))
                    }
                }
            }
        }

        if ($violations.Count -gt 0) {
            $message = @(
                'Found forbidden phase-number labels in governed paths:'
                ($violations -join [Environment]::NewLine)
            ) -join [Environment]::NewLine
            throw $message
        }
    }
}
