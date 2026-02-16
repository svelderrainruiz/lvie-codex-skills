# Agent Quickstart (labview-icon-editor)

Last validated: 2026-02-15
Validation evidence: skills repo CI-coupled release gate

## Purpose
Get an agent productive in under 10 minutes for CI triage, release GO/NO-GO, and artifact verification.

## 1) Establish context
- Skills repo: `<owner>/lvie-codex-skills`
- Source project repo: `<owner>/labview-icon-editor`
- CI gate workflow: `.github/workflows/ci.yml`
- Release workflow: `.github/workflows/release-skill-layer.yml`

## 2) First 5 commands (authenticated)
```powershell
gh auth status
```

```powershell
gh run list --repo <owner>/lvie-codex-skills --workflow ci.yml --limit 5
```

```powershell
gh api repos/<owner>/lvie-codex-skills/actions/runs/<RUN_ID> --jq '{status, conclusion, head_sha, head_branch, run_attempt, updated_at}'
```

```powershell
gh api repos/<owner>/lvie-codex-skills/actions/runs/<RUN_ID>/jobs --paginate --jq '.jobs[] | {name, status, conclusion}'
```

```powershell
gh api repos/<owner>/lvie-codex-skills/actions/runs/<RUN_ID>/artifacts --jq '.artifacts[] | .name'
```

## 3) GO/NO-GO gate (minimum)
A release candidate run is GO-eligible only if all are true:
- status = completed
- conclusion = success
- no required job has failure/cancelled/timed_out/startup_failure/action_required
- required artifacts exist:
  - `docker-contract-ppl-bundle-windows-x64-<run_id>`
  - `docker-contract-ppl-bundle-linux-x64-<run_id>`
  - `docker-contract-vip-package-self-hosted-<run_id>`

If any condition fails: NO-GO (no release publish).

Non-gating diagnostic lanes in `ci.yml` (advisory, not GO/NO-GO blockers):
- `validate-pylavi-docker-source-project` (artifact `docker-contract-pylavi-source-project-<run_id>`)
- `build-runner-cli-linux-docker` (artifact `docker-contract-runner-cli-linux-x64-<run_id>`)
- `build-x86-ppl-linux-shadow` (artifacts `docker-contract-ppl-linux-raw-x86-<run_id>`, `docker-contract-ppl-bundle-linux-x86-<run_id>`, `docker-contract-ppl-linux-x86-shadow-diagnostics-<run_id>`)

## 4) Dispatch source of truth
Use skills repo release workflow inputs in `.github/workflows/release-skill-layer.yml`:
- `release_tag`
- `consumer_repo` (source project repo)
- `consumer_ref` (source project ref)
- `consumer_sha` (source project SHA)
- `labview_profile` (LabVIEW target preset id)
- `source_labview_version_override` (optional effective `.lvversion` override, `major.minor`, minimum `20.0`)

Compatibility-only (deprecated) inputs:
- `run_self_hosted`
- `run_build_spec`

## 4.1) Deterministic post-merge auto-release
- `release-skill-layer` runs automatically on `push` to `main`.
- Auto-release resolver derives:
  - `release_tag` as `v<manifest.version>`.
  - `consumer_repo`, `consumer_ref`, `consumer_sha`, and `labview_profile` from:
    - workflow input (manual dispatch),
    - repository variables (`LVIE_SOURCE_PROJECT_*`, `LVIE_LABVIEW_PROFILE`),
    - deterministic fallback (`<owner>/labview-icon-editor`, `main`) for repo/ref.
  - strict source SHA pin is required (`LVIE_SOURCE_PROJECT_SHA` or explicit dispatch input).
- If the resolved tag already exists, workflow follows deterministic skip path:
  - `should_release=false`
  - `skip_reason=tag_exists`
  - `release-skipped` job succeeds and publishes skip summary.
- `workflow_dispatch` remains available for explicit overrides and reruns with operator-provided inputs.

## 4.2) One-time fork bootstrap
Initialize portability variables once in the forked skills repo:

```powershell
pwsh -NoProfile -File ./scripts/Initialize-ForkPortability.ps1 `
  -SkillsRepo '<owner>/lvie-codex-skills' `
  -SourceProjectRepo '<owner>/labview-icon-editor' `
  -SourceProjectRef 'main'
```

Rotate strict SHA pin later without changing repo/ref:

```powershell
pwsh -NoProfile -File ./scripts/Initialize-ForkPortability.ps1 `
  -SkillsRepo '<owner>/lvie-codex-skills' `
  -RefreshSourceSha
```

## 5) Provenance fields expected in release notes
- `skills_ci_repo`
- `skills_ci_run_url`
- `skills_ci_run_id`
- `skills_ci_run_attempt`
- `source_project_repo`
- `source_project_ref`
- `source_project_sha`

## 6) Fast escalation path
- If run is still `queued`/`in_progress`: monitor and do not publish.
- If run is `completed` + `failure`: capture failed jobs, mark NO-GO, and rerun after fixes.
- If run is `completed` + `success`: verify required artifacts and proceed with release publish.

## 6.1) Self-hosted scheduling and remote triage
- Verify required runner labels exist on at least one online runner:
```powershell
gh api repos/<owner>/lvie-codex-skills/actions/runners --jq '.runners[] | {name, status, labels: [.labels[].name]}'
```
- `run-lunit-smoke-x64` uses resolved source-year x64 label from `resolve-labview-profile` output (`self-hosted-windows-lv<YYYY>x64`).
- Self-hosted jobs enforce source-project remote hygiene via `Assert-SourceProjectRemotes.ps1`:
  - sets/updates `upstream` to `https://github.com/<source-project-repo>.git`
  - validates non-interactive `git ls-remote upstream`
  - fails hard when remote connectivity/auth is broken
- LV2020 smoke command contract is run-only:
  - `g-cli --lv-ver <YYYY> --arch 64 lunit -- -r <report> <project.lvproj>`
  - no deterministic `g-cli ... lunit -- -h` preflight.
- VIP package build path uses VIPM CLI:
  - `Invoke-VipmBuildPackage.ps1` runs `vipm --labview-version <YYYY> --labview-bitness 64 build <vipb>`
  - g-cli is limited to LUnit smoke only.
- Source-year override behavior:
  - required job key is `run-lunit-smoke-x64`,
  - execution target year and `.lvversion` are resolved from effective target selection in `resolve-labview-profile`,
  - when provided, `source_labview_version_override` is authoritative for CI execution target (format `major.minor`; Minimum supported LabVIEW version is 20.0),
  - when override is omitted, source project `.lvversion` is used.
- CI invokes `Invoke-LunitSmoke.ps1` with `-EnforceLabVIEWProcessIsolation`, so active LabVIEW processes are cleared before the smoke run.
- The LUnit smoke lane has no VIPM preflight dependency.
- Report validation failures remain blocking for downstream self-hosted jobs.
- Triage order for LUnit smoke:
  1. `lunit-smoke.result.json`
  2. `reports/lunit-report-lv<effective_year>-x64.xml`
  3. `lunit-smoke.log`

## 6.2) Runner PowerShell policy baseline
- Required baseline for Windows/self-hosted runners:
```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force
```
- Verify policy matrix:
```powershell
Get-ExecutionPolicy -List
```
- CI enforces this with `scripts/Initialize-RunnerPowerShellPolicy.ps1` and `scripts/Unblock-WorkspaceScripts.ps1`.
- Do not pass execution-policy override flags in repo-owned commands, workflow snippets, or local runbooks.

## 7) Canonical references
- `.github/workflows/ci.yml`
- `.github/workflows/release-skill-layer.yml`
- `docs/agents/release-gates.md`

## 8) Release payload files
When `release-skill-layer` publishes a tag, expect:
- `lvie-codex-skill-layer-installer.exe`
- `lvie-ppl-bundle-windows-x64.zip`
- `lvie-ppl-bundle-linux-x64.zip`
- `lvie-ppl-bundle-linux-x86.zip`
- `lvie-vip-package-self-hosted.zip`
- `release-provenance.json`
- `release-payload-manifest.json`


