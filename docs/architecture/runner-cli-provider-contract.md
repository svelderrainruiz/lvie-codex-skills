# Runner-CLI Provider Contract (M1 Freeze)

Status: draft contract freeze for issue #34 milestone M1.

## Goal
Lock a single orchestration interface for build/test/package lanes before implementation migration.

## Canonical command surface
- `runner-cli ppl build`
- `runner-cli vip build`
- `runner-cli lunit run`
- `runner-cli lunit validate`

## Provider model
- `selfhosted`
- `linux-container`
- `windows-container`

Provider choice is explicit for `ppl build`. Backend internals stay provider-specific, but command contract and result schema remain shared.

## Bitness model
- `x64`
- `x86`

Bitness is explicit in the command contract. No implicit fallback from workflow lane names.

## `runner-cli ppl build` minimum options
- `--provider <selfhosted|linux-container|windows-container>`
- `--bitness <x64|x86>`
- `--target-os <windows|linux>`
- `--repo-root <path>`
- `--output-directory <path>`

Optional:
- `--labview-version <year>`
- `--image <container-image>` (container providers)
- `--shadow <true|false>`
- `--dry-run`

## Contract invariants
1. Shared status/result payload shape across providers.
2. Explicit provider + bitness in every invocation.
3. Self-hosted execution remains serializable via lane-level concurrency controls.
4. Container lanes remain parallel unless explicitly restricted.
5. Teardown ownership policy is unchanged:
   - LabVIEWCLI-owned operations close with LabVIEWCLI.
   - g-cli-owned operations close with g-cli.

## Schema
Contract schema: `schemas/runner-cli-provider-command.schema.json`

## Out of scope for M1
- Workflow gate topology changes.
- Promotion policy cutover.
- Backend implementation rewrites.
