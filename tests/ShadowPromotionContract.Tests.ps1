#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Shadow promotion control-plane contract' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:bridgeScriptPath = Join-Path $script:repoRoot 'scripts/Invoke-ShadowPromotionEvaluation.ps1'
        $script:orchestrationScriptPath = Join-Path $script:repoRoot 'scripts/Invoke-ShadowPromotionGate.ps1'
        $script:workflowPath = Join-Path $script:repoRoot '.github/workflows/shadow-promotion-gate.yml'
        $script:sourcePath = Join-Path $script:repoRoot 'control-plane/src/index.ts'
        $script:distPath = Join-Path $script:repoRoot 'control-plane/dist/index.js'
        $script:schemaPath = Join-Path $script:repoRoot 'schemas/shadow-promotion-state.schema.json'

        foreach ($path in @(
            $script:bridgeScriptPath,
            $script:orchestrationScriptPath,
            $script:workflowPath,
            $script:sourcePath,
            $script:distPath,
            $script:schemaPath
        )) {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Required shadow-promotion contract artifact missing: $path"
            }
        }

        $script:bridgeContent = Get-Content -LiteralPath $script:bridgeScriptPath -Raw
        $script:orchestrationContent = Get-Content -LiteralPath $script:orchestrationScriptPath -Raw
        $script:workflowContent = Get-Content -LiteralPath $script:workflowPath -Raw
        $script:sourceContent = Get-Content -LiteralPath $script:sourcePath -Raw
        $script:distContent = Get-Content -LiteralPath $script:distPath -Raw
        $script:schema = Get-Content -LiteralPath $script:schemaPath -Raw | ConvertFrom-Json -ErrorAction Stop
    }

    It 'routes wrapper script through control-plane shadow-promotion-evaluate command' {
        $script:bridgeContent | Should -Match "Invoke-ControlPlaneBridge\s+-Command\s+'shadow-promotion-evaluate'"
        $script:bridgeContent | Should -Match '\$MinConsecutiveGreens\s*=\s*5'
        $script:bridgeContent | Should -Match 'RequiredLaneNames'
        $script:bridgeContent | Should -Match 'ShadowLaneNames'
    }

    It 'collects recent CI runs, normalizes green-run metrics, and invokes shadow-promotion evaluation from orchestration script' {
        $script:orchestrationContent | Should -Match 'actions/workflows/\$escapedWorkflowFile/runs\?branch=\$escapedBranch&status=completed&per_page=\$MaxRunsToScan'
        $script:orchestrationContent | Should -Match "Invoke-Gh -Arguments @\('run', 'download'"
        $script:orchestrationContent | Should -Match 'green-run-\{0\}\.json'
        $script:orchestrationContent | Should -Match 'Invoke-ShadowPromotionEvaluation\.ps1'
        $script:orchestrationContent | Should -Match '\[int\]\$MinConsecutiveGreens\s*=\s*5'
        $script:orchestrationContent | Should -Match "ShadowLaneName = 'build-ppl-container-linux-x86-shadow'"
    }

    It 'defines promotion-only blocking workflow with five-green summary artifact evidence' {
        $script:workflowContent | Should -Match 'name:\s*shadow-promotion-gate'
        $script:workflowContent | Should -Match 'pull_request:\s*[\s\S]*?contracts/build-lane-matrix\.json'
        $script:workflowContent | Should -Match 'pull_request:\s*[\s\S]*?\.github/workflows/ci\.yml'
        $script:workflowContent | Should -Match 'Detect linux x86 shadow promotion attempt'
        $script:workflowContent | Should -Match 'promotion_attempt='
        $script:workflowContent | Should -Match 'Invoke-ShadowPromotionGate\.ps1'
        $script:workflowContent | Should -Match '-MinConsecutiveGreens 5'
        $script:workflowContent | Should -Match 'shadow-promotion-state-\$\{\{\s*github\.run_id\s*\}\}'
        $script:workflowContent | Should -Match "if:\s*\$\{\{\s*steps\.detect\.outputs\.promotion_attempt == 'true' && steps\.summary\.outputs\.promotion_ready != 'true'\s*\}\}"
        $script:workflowContent | Should -Match '## Shadow Promotion State'
        $script:workflowContent | Should -Match 'threshold:'
        $script:workflowContent | Should -Match 'consecutive green count:'
        $script:workflowContent | Should -Match 'promotion ready:'
        $script:workflowContent | Should -Match 'reset reason:'
        $script:workflowContent | Should -Match 'evaluated run IDs:'
    }

    It 'implements default five-green threshold and reset reasons in control-plane source and dist runtime' {
        foreach ($content in @($script:sourceContent, $script:distContent)) {
            $content | Should -Match 'DEFAULT_SHADOW_PROMOTION_MIN_GREENS\s*=\s*5'
            $content | Should -Match 'shadow-promotion-evaluate'
            $content | Should -Match 'non_authoritative_head'
            $content | Should -Match 'required_lane_failure'
            $content | Should -Match 'shadow_lane_failure'
            $content | Should -Match 'rollout_signature_changed'
            $content | Should -Match 'runner_pool_changed'
        }
    }

    It 'defines schema for promotion state output with evaluated runs list' {
        @($script:schema.required) | Should -Contain 'threshold'
        @($script:schema.required) | Should -Contain 'consecutive_green_count'
        @($script:schema.required) | Should -Contain 'promotion_ready'
        @($script:schema.required) | Should -Contain 'reset_reason'
        @($script:schema.required) | Should -Contain 'evaluated_runs'
        $script:schema.properties.evaluated_runs.items.required | Should -Contain 'qualifies'
        $script:schema.properties.evaluated_runs.items.required | Should -Contain 'disqualifier'
    }
}
