#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Release metrics scaffold contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:governanceRoot = Join-Path $script:repoRoot 'docs/release-governance'
        $script:metricsContractPath = Join-Path $script:governanceRoot 'metrics-loop.contract.json'
        $script:metricsRunbookPath = Join-Path $script:governanceRoot 'metrics-review-runbook.md'
        $script:metricsSchemaPath = Join-Path $script:repoRoot 'schemas/release-metrics.schema.json'
        $script:greenSchemaPath = Join-Path $script:repoRoot 'schemas/control-plane-green-run.schema.json'
        $script:metricsScriptPath = Join-Path $script:repoRoot 'scripts/Invoke-ReleaseMetricsSnapshot.ps1'
        $script:controlPlanePath = Join-Path $script:repoRoot 'control-plane/dist/index.js'

        foreach ($path in @(
            $script:metricsContractPath,
            $script:metricsRunbookPath,
            $script:metricsSchemaPath,
            $script:greenSchemaPath,
            $script:metricsScriptPath,
            $script:controlPlanePath
        )) {
            if (-not (Test-Path -Path $path -PathType Leaf)) {
                throw "Release metrics artifact missing: $path"
            }
        }

        $script:metricsContract = Get-Content -Raw -Path $script:metricsContractPath | ConvertFrom-Json -ErrorAction Stop
        $script:metricsSchema = Get-Content -Raw -Path $script:metricsSchemaPath | ConvertFrom-Json -ErrorAction Stop
        $script:greenSchema = Get-Content -Raw -Path $script:greenSchemaPath | ConvertFrom-Json -ErrorAction Stop
        $script:metricsRunbook = Get-Content -Raw -Path $script:metricsRunbookPath
        $script:metricsScript = Get-Content -Raw -Path $script:metricsScriptPath
        $script:controlPlaneContent = Get-Content -Raw -Path $script:controlPlanePath
    }

    It 'defines required metrics and gate outcomes in the contract' {
        $script:metricsContract.required_metrics | Should -Contain 'gate_outcome'
        $script:metricsContract.required_metrics | Should -Contain 'rollback_triggered'
        $script:metricsContract.required_metrics | Should -Contain 'missing_required_artifact_count'
        $script:metricsContract.gate_outcomes | Should -Contain 'go'
        $script:metricsContract.gate_outcomes | Should -Contain 'no-go'
    }

    It 'defines release metrics schema fields for gate and failures' {
        $script:metricsSchema.required | Should -Contain 'gate_outcome'
        $script:metricsSchema.required | Should -Contain 'failed_job_count'
        $script:metricsSchema.required | Should -Contain 'top_failure_causes'
        $script:metricsSchema.properties.PSObject.Properties.Name | Should -Contain 'rollback_triggered'
    }

    It 'defines green-run schema for qualifying run performance metadata' {
        $script:greenSchema.required | Should -Contain 'run_id'
        $script:greenSchema.required | Should -Contain 'head_sha'
        $script:greenSchema.required | Should -Contain 'required_lanes_passed'
        $script:greenSchema.required | Should -Contain 'artifact_contract_hashes'
        $script:greenSchema.properties.PSObject.Properties.Name | Should -Contain 'lane_name'
        $script:greenSchema.properties.PSObject.Properties.Name | Should -Contain 'lane_role'
        $script:greenSchema.properties.PSObject.Properties.Name | Should -Contain 'ppl_target_os'
        $script:greenSchema.properties.PSObject.Properties.Name | Should -Contain 'ppl_bitness'
        $script:greenSchema.properties.PSObject.Properties.Name | Should -Contain 'container_image'
        $script:greenSchema.properties.PSObject.Properties.Name | Should -Contain 'duration_seconds'
        $script:greenSchema.properties.PSObject.Properties.Name | Should -Contain 'status'
    }

    It 'includes review and improvement sections in the runbook' {
        $script:metricsRunbook | Should -Match '(?m)^## Collection\s*$'
        $script:metricsRunbook | Should -Match '(?m)^## Weekly Review\s*$'
        $script:metricsRunbook | Should -Match '(?m)^## Continuous Improvement Actions\s*$'
    }

    It 'routes metrics collection through the control-plane runtime and emits green-run artifacts' {
        $script:metricsScript | Should -Match "Invoke-ControlPlaneBridge\s+-Command\s+'release-metrics'"
        $script:controlPlaneContent | Should -Match 'release-metrics-'
        $script:controlPlaneContent | Should -Match 'green-run-'
    }
}
