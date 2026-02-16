# ADR 0001: Deterministic Build Platform and Smart Control Loop

- Status: Proposed
- Date: 2026-02-16
- Tracking issue: https://github.com/svelderrainruiz/lvie-codex-skills/issues/34

## Context
Current orchestration is distributed across workflow jobs and script entrypoints with provider-specific behavior exposed at the lane level. That increases drift risk for diagnostics, release payloads, and promotion policy decisions.

The target operating model is a deterministic build platform:
- one command contract per domain,
- multiple execution providers under the same contract,
- policy-driven promotion and rollback,
- provenance-first release payload generation.

## Decision
Adopt a platform architecture with these constraints:

1. Declarative lane graph becomes the source of truth.
2. `runner-cli` is the single orchestration kernel for build/test/package domains.
3. Provider internals are hidden behind stable contracts:
   - `selfhosted`
   - `linux-container`
   - `windows-container`
4. Promotion and rollback are controlled by smart-control-loop policy from emitted metrics evidence.
5. Release payload manifest is generated from lane graph contracts, not ad-hoc workflow wiring.

## Command Surface (Target)
- `runner-cli ppl build --provider <selfhosted|linux-container|windows-container> --bitness <32|64>`
- `runner-cli vip build`
- `runner-cli lunit run`
- `runner-cli lunit validate`

## Schema Skeleton
Initial contract file: `schemas/build-lane-matrix.schema.json`

Key fields:
- `lane_id`
- `display_name`
- `provider`
- `target_os`
- `bitness`
- `role` (`required|shadow`)
- `required` (boolean)
- `artifact_name`
- `container_image` (nullable for selfhosted)
- `metrics_category`

## Milestones
1. M0 Architecture freeze
- ADR + schema draft approved.

2. M1 Command contract freeze
- runner-cli provider/bitness surface approved.
- no topology change.

3. M2 Lane migration
- all PPL lanes routed through provider-based runner-cli commands.
- artifact and gate semantics preserved.

4. M3 Smart control loop cutover
- policy-driven promotion/rollback from metrics evidence.
- 5-green streak policy operationalized.

5. M4 Release contract unification
- payload assembly and manifest generation from lane graph contracts.
- provenance verification required.

6. M5 Legacy retirement
- remove superseded orchestration paths and stale policy debt.

## Consequences
Positive:
- consistent orchestration and diagnostics across providers,
- deterministic promotion logic,
- lower workflow complexity and drift.

Tradeoffs:
- upfront migration complexity,
- temporary dual-path maintenance during cutover.

## Non-goals
- changing required check context names in this ADR.
- introducing new workflow files outside scoped migration PRs.
