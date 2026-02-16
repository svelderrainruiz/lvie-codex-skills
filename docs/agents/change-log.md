# Agent Docs Change Log

## 2026-02-16 — Deterministic platform architecture and M1 contract freeze
- Added architecture ADR: `docs/architecture/adr-0001-deterministic-build-platform.md`.
- Added M1 provider/bitness contract doc: `docs/architecture/runner-cli-provider-contract.md`.
- Added lane graph schema skeleton: `schemas/build-lane-matrix.schema.json`.
- Added runner-cli provider command schema: `schemas/runner-cli-provider-command.schema.json`.

## 2026-02-13 — Runner-CLI dispatch foundation planning
- Added `runner-cli-dispatch-foundation-plan.md` to define control-plane integration scope.
- Locked dispatch foundation scope to dispatch/run-query adapters with preserved `gh`/REST fallback behavior.
- Documented acceptance criteria, validation gates, and non-goals to prevent schema-breaking drift.

## 2026-02-13 — Run evidence backfill
- Updated `quickstart.md` with 3-run outcomes table and canonical release-plan references.
- Updated `release-gates.md` with explicit evidence backfill table for runs:
  - 22002791381
  - 22004004032
  - 22005219153
- Updated `ci-catalog.md` with recent failure evidence and active branch context.

### Evidence links
- https://github.com/svelderrainruiz/labview-icon-editor/actions/runs/22002791381
- https://github.com/svelderrainruiz/labview-icon-editor/actions/runs/22004004032
- https://github.com/svelderrainruiz/labview-icon-editor/actions/runs/22005219153

### Notes
- 22002791381 and 22004004032 are terminal NO-GO examples (same blocker jobs failed).
- 22005219153 remains non-terminal and missing packed library artifacts at last validation snapshot.
