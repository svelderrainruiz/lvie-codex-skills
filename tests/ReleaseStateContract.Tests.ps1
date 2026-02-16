#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Release state control-plane contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:releaseStateSchemaPath = Join-Path $script:repoRoot 'schemas/release-state.schema.json'
        $script:dispatchResultSchemaPath = Join-Path $script:repoRoot 'schemas/dispatch-result.schema.json'
        $script:watcherPath = Join-Path $script:repoRoot 'scripts/Watch-RunAndUpdatePlan.ps1'
        $script:orchestratorPath = Join-Path $script:repoRoot 'scripts/Invoke-ReleaseOrchestrator.ps1'
        $script:metricsPath = Join-Path $script:repoRoot 'scripts/Invoke-ReleaseMetricsSnapshot.ps1'
        $script:bridgePath = Join-Path $script:repoRoot 'scripts/Invoke-ControlPlaneBridge.ps1'
        $script:controlPlanePath = Join-Path $script:repoRoot 'control-plane/dist/index.js'

        foreach ($path in @(
            $script:releaseStateSchemaPath,
            $script:dispatchResultSchemaPath,
            $script:watcherPath,
            $script:orchestratorPath,
            $script:metricsPath,
            $script:bridgePath,
            $script:controlPlanePath
        )) {
            if (-not (Test-Path -Path $path -PathType Leaf)) {
                throw "Required release-state artifact missing: $path"
            }
        }

        $script:releaseStateSchema = Get-Content -Raw -Path $script:releaseStateSchemaPath | ConvertFrom-Json -ErrorAction Stop
        $script:dispatchResultSchema = Get-Content -Raw -Path $script:dispatchResultSchemaPath | ConvertFrom-Json -ErrorAction Stop
        $script:watcherContent = Get-Content -Raw -Path $script:watcherPath
        $script:orchestratorContent = Get-Content -Raw -Path $script:orchestratorPath
        $script:metricsContent = Get-Content -Raw -Path $script:metricsPath
        $script:controlPlaneContent = Get-Content -Raw -Path $script:controlPlanePath
    }

    It 'defines release-state schema with gate and go-eligibility fields' {
        $script:releaseStateSchema.required | Should -Contain 'gate'
        $script:releaseStateSchema.required | Should -Contain 'is_go_eligible'
        $script:releaseStateSchema.properties.PSObject.Properties.Name | Should -Contain 'required_artifacts'
        $script:releaseStateSchema.properties.PSObject.Properties.Name | Should -Contain 'missing_required_artifacts'
    }

    It 'defines dispatch-result schema for no-go, dry-run, and dispatched statuses' {
        $script:dispatchResultSchema.properties.status.enum | Should -Contain 'no-go'
        $script:dispatchResultSchema.properties.status.enum | Should -Contain 'go-dry-run'
        $script:dispatchResultSchema.properties.status.enum | Should -Contain 'dispatched'
        $script:dispatchResultSchema.properties.PSObject.Properties.Name | Should -Contain 'release_state_path'
    }

    It 'routes release watcher, orchestrator, and metrics scripts through control-plane commands' {
        $script:watcherContent | Should -Match "Invoke-ControlPlaneBridge\s+-Command\s+'release-watch'"
        $script:orchestratorContent | Should -Match "Invoke-ControlPlaneBridge\s+-Command\s+'release-orchestrator'"
        $script:metricsContent | Should -Match "Invoke-ControlPlaneBridge\s+-Command\s+'release-metrics'"
    }

    It 'keeps owner-repo context resolution and required artifact prefixes in runtime logic' {
        $script:controlPlaneContent | Should -Match 'GITHUB_REPOSITORY'
        $script:controlPlaneContent | Should -Match 'git.*remote.*get-url.*origin'
        $script:controlPlaneContent | Should -Match 'docker-contract-ppl-container-windows-x64-'
        $script:controlPlaneContent | Should -Match 'docker-contract-ppl-container-linux-x64-'
        $script:controlPlaneContent | Should -Match 'docker-contract-ppl-selfhosted-windows-x86-'
        $script:controlPlaneContent | Should -Match 'docker-contract-vip-package-self-hosted-'
    }
}
