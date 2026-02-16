#Requires -Version 7.0
#Requires -Modules Pester

$ErrorActionPreference = 'Stop'

Describe 'Runner-cli provider contract (issue-34 M1 freeze)' {
    BeforeAll {
        $script:repoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot '..')).Path
        $script:schemaPath = Join-Path $script:repoRoot 'schemas/runner-cli-provider-command.schema.json'
        $script:docPath = Join-Path $script:repoRoot 'docs/architecture/runner-cli-provider-contract.md'
        $script:adrPath = Join-Path $script:repoRoot 'docs/architecture/adr-0001-deterministic-build-platform.md'

        foreach ($path in @($script:schemaPath, $script:docPath, $script:adrPath)) {
            if (-not (Test-Path -Path $path -PathType Leaf)) {
                throw "Required contract artifact missing: $path"
            }
        }

        $script:schema = Get-Content -Raw -Path $script:schemaPath | ConvertFrom-Json -ErrorAction Stop
        $script:docContent = Get-Content -Raw -Path $script:docPath
        $script:adrContent = Get-Content -Raw -Path $script:adrPath
    }

    It 'defines the runner-cli provider command schema with expected top-level fields' {
        @($script:schema.required) | Should -Contain 'schema_version'
        @($script:schema.required) | Should -Contain 'commands'
        [string]$script:schema.properties.schema_version.const | Should -Be '1.0'
    }

    It 'locks ppl build provider and bitness enums' {
        $ppl = $script:schema.properties.commands.properties.ppl_build
        @($ppl.required) | Should -Contain 'provider_enum'
        @($ppl.required) | Should -Contain 'bitness_enum'
        @($ppl.required) | Should -Contain 'target_os_enum'

        @($ppl.properties.provider_enum.items.enum) | Should -Contain 'selfhosted'
        @($ppl.properties.provider_enum.items.enum) | Should -Contain 'linux-container'
        @($ppl.properties.provider_enum.items.enum) | Should -Contain 'windows-container'

        @($ppl.properties.bitness_enum.items.enum) | Should -Contain 'x64'
        @($ppl.properties.bitness_enum.items.enum) | Should -Contain 'x86'

        @($ppl.properties.target_os_enum.items.enum) | Should -Contain 'windows'
        @($ppl.properties.target_os_enum.items.enum) | Should -Contain 'linux'
    }

    It 'requires explicit ppl build invocation options for provider and bitness' {
        $ppl = $script:schema.properties.commands.properties.ppl_build
        $requiredOptionMarkers = @($ppl.properties.required_options.allOf | ForEach-Object { [string]$_.contains.const })
        $requiredOptionMarkers | Should -Contain '--provider'
        $requiredOptionMarkers | Should -Contain '--bitness'
        $requiredOptionMarkers | Should -Contain '--target-os'
        $requiredOptionMarkers | Should -Contain '--repo-root'
        $requiredOptionMarkers | Should -Contain '--output-directory'
    }

    It 'documents the provider model and command surface in architecture docs' {
        $script:docContent | Should -Match 'runner-cli ppl build'
        $script:docContent | Should -Match 'selfhosted'
        $script:docContent | Should -Match 'linux-container'
        $script:docContent | Should -Match 'windows-container'
        $script:docContent | Should -Match 'x64'
        $script:docContent | Should -Match 'x86'
        $script:docContent | Should -Match 'schemas/runner-cli-provider-command\.schema\.json'

        $script:adrContent | Should -Match 'runner-cli ppl build --provider'
        $script:adrContent | Should -Match 'runner-cli lunit validate'
    }
}
