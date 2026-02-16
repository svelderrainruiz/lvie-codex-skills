#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Autonomous CI loop adapter contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:loopPath = Join-Path $script:repoRoot 'scripts/Invoke-AutonomousCiLoop.ps1'
        $script:bridgePath = Join-Path $script:repoRoot 'scripts/Invoke-ControlPlaneBridge.ps1'
        $script:controlPlaneDist = Join-Path $script:repoRoot 'control-plane/dist/index.js'
        $script:controlPlaneSource = Join-Path $script:repoRoot 'control-plane/src/index.ts'

        foreach ($path in @($script:loopPath, $script:bridgePath, $script:controlPlaneDist, $script:controlPlaneSource)) {
            if (-not (Test-Path -Path $path -PathType Leaf)) {
                throw "Required control-plane artifact missing: $path"
            }
        }

        $script:loopContent = Get-Content -Raw -Path $script:loopPath
        $script:controlPlaneContent = Get-Content -Raw -Path $script:controlPlaneDist
    }

    It 'routes loop execution through the control-plane bridge' {
        $script:loopContent | Should -Match 'Invoke-ControlPlaneBridge\.ps1'
        $script:loopContent | Should -Match "Invoke-ControlPlaneBridge\s+-Command\s+'autonomous-loop'"
    }

    It 'keeps configurable dispatch and run-query backend options on the adapter surface' {
        $script:loopContent | Should -Match "ValidateSet\('auto', 'runner-cli', 'gh'\)"
        $script:loopContent | Should -Match 'DispatchBackend'
        $script:loopContent | Should -Match 'RunQueryBackend'
    }

    It 'implements dispatch correlation, head SHA authority checks, and green-run metrics emission in control-plane runtime' {
        $script:controlPlaneContent | Should -Match 'Unable to correlate dispatched workflow run'
        $script:controlPlaneContent | Should -Match 'expectedHeadSha'
        $script:controlPlaneContent | Should -Match 'green-run-'
        $script:controlPlaneContent | Should -Match 'required_lanes_passed'
    }
}
