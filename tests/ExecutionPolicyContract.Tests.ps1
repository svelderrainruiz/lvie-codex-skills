#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Execution policy contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:governedPatterns = @(
            '.github/workflows/*.yml',
            'scripts/*.ps1',
            'tests/*.Tests.ps1',
            'docs/**/*.md',
            'README.md'
        )
        $script:allowedValues = @('RemoteSigned', 'AllSigned', 'Restricted', 'Undefined', 'Default')
    }

    It 'uses only allowlisted execution policy values in governed paths' {
        $violations = New-Object System.Collections.Generic.List[string]

        foreach ($pattern in $script:governedPatterns) {
            $paths = Get-ChildItem -Path (Join-Path $script:repoRoot $pattern) -File -ErrorAction SilentlyContinue
            foreach ($path in $paths) {
                if ($path.Name -eq 'ExecutionPolicyContract.Tests.ps1') {
                    continue
                }

                $lineNumber = 0
                foreach ($line in Get-Content -LiteralPath $path.FullName) {
                    $lineNumber++

                    foreach ($match in [regex]::Matches($line, '(?i)(?:^|\s)-ExecutionPolicy\s+([A-Za-z]+)')) {
                        $value = [string]$match.Groups[1].Value
                        if ($script:allowedValues -notcontains $value) {
                            $violations.Add(('{0}:{1}: non-allowlisted -ExecutionPolicy value ''{2}''' -f $path.FullName, $lineNumber, $value))
                        }
                    }

                    foreach ($match in [regex]::Matches($line, '(?i)\bExecutionPolicy=([A-Za-z]+)\b')) {
                        $value = [string]$match.Groups[1].Value
                        if ($script:allowedValues -notcontains $value) {
                            $violations.Add(('{0}:{1}: non-allowlisted ExecutionPolicy= value ''{2}''' -f $path.FullName, $lineNumber, $value))
                        }
                    }
                }
            }
        }

        if ($violations.Count -gt 0) {
            $message = @(
                'Execution policy contract violations found:'
                ($violations -join [Environment]::NewLine)
            ) -join [Environment]::NewLine
            throw $message
        }
    }
}
