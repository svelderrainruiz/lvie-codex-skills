#!/usr/bin/env node
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const BAD_JOB_CONCLUSIONS = new Set([
  'failure',
  'cancelled',
  'timed_out',
  'startup_failure',
  'action_required'
]);

const REQUIRED_ARTIFACT_PREFIXES = [
  'docker-contract-ppl-container-windows-x64-',
  'docker-contract-ppl-container-linux-x64-',
  'docker-contract-ppl-selfhosted-windows-x86-',
  'docker-contract-vip-package-self-hosted-'
];
const DEFAULT_SHADOW_PROMOTION_MIN_GREENS = 5;

function asString(value) {
  if (value === null || value === undefined) {
    return '';
  }
  return String(value);
}

function asInt(value, fallback) {
  const parsed = Number.parseInt(asString(value), 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function asBool(value, fallback = false) {
  const text = asString(value).trim().toLowerCase();
  if (text.length === 0) {
    return fallback;
  }
  if (['1', 'true', 'yes', 'y', 'on'].includes(text)) {
    return true;
  }
  if (['0', 'false', 'no', 'n', 'off'].includes(text)) {
    return false;
  }
  return fallback;
}

function asStringArray(value) {
  if (Array.isArray(value)) {
    return value.map((entry) => asString(entry).trim()).filter((entry) => entry.length > 0);
  }

  const text = asString(value).trim();
  if (text.length === 0) {
    return [];
  }

  if (text.startsWith('[') && text.endsWith(']')) {
    try {
      const parsed = JSON.parse(text);
      if (Array.isArray(parsed)) {
        return parsed.map((entry) => asString(entry).trim()).filter((entry) => entry.length > 0);
      }
    } catch {
      // Fall back to delimiter split.
    }
  }

  return text
    .split(/[;,]/)
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0);
}

function parseJson(raw, label) {
  try {
    return JSON.parse(raw);
  } catch (error) {
    throw new Error(`Unable to parse ${label}: ${error.message}`);
  }
}

function run(filePath, args, cwd) {
  const result = spawnSync(filePath, args, {
    cwd,
    encoding: 'utf8',
    shell: false,
    env: process.env
  });
  const status = typeof result.status === 'number' ? result.status : (result.error ? 127 : 0);
  const stdout = asString(result.stdout).trimEnd();
  const stderr = asString(result.stderr).trimEnd();
  const output = [];
  if (stdout.length > 0) {
    output.push(...stdout.split(/\r?\n/));
  }
  if (stderr.length > 0) {
    output.push(...stderr.split(/\r?\n/));
  }
  return { status, stdout, stderr, output };
}

function repoRoot() {
  return path.resolve(path.dirname(new URL(import.meta.url).pathname), '..', '..');
}

function ensureDir(dirPath) {
  fs.mkdirSync(dirPath, { recursive: true });
}

function sleep(seconds) {
  if (seconds <= 0) {
    return;
  }
  const signal = new Int32Array(new SharedArrayBuffer(4));
  Atomics.wait(signal, 0, 0, Math.floor(seconds * 1000));
}

function inferOwnerRepo(value, cwd) {
  const explicit = asString(value).trim();
  if (explicit.length > 0) {
    return explicit;
  }
  if (asString(process.env.GITHUB_REPOSITORY).trim().length > 0) {
    return asString(process.env.GITHUB_REPOSITORY).trim();
  }
  const probe = run('git', ['remote', 'get-url', 'origin'], cwd);
  if (probe.status === 0) {
    const match = probe.stdout.trim().match(/github\.com[:/]([^/]+\/[^/.]+?)(?:\.git)?$/i);
    if (match) {
      return match[1];
    }
  }
  throw new Error('OwnerRepo was not provided and could not be inferred.');
}

function inferOrchestratorRef(cwd) {
  const explicit = asString(process.env.CONTROL_PLANE_WORKFLOW_REF).trim();
  if (explicit.length > 0) {
    return explicit;
  }

  const branchProbe = run('git', ['branch', '--show-current'], cwd);
  if (branchProbe.status === 0) {
    const branch = branchProbe.stdout.trim();
    if (branch.length > 0) {
      return branch;
    }
  }

  return 'main';
}

function writeDispatchResult({
  path: outputPath,
  status,
  runId,
  releaseTag,
  ownerRepo,
  consumerRef,
  consumerSha,
  skillRepo,
  workflowRef,
  planPath,
  releaseStatePath,
  method
}) {
  ensureDir(path.dirname(outputPath));
  const payload = {
    schema_version: '1.0',
    generated_utc: new Date().toISOString(),
    status,
    method,
    run_id: runId,
    release_tag: releaseTag,
    owner_repo: ownerRepo,
    consumer_ref: consumerRef,
    consumer_sha: consumerSha,
    skill_repo: skillRepo,
    workflow_ref: workflowRef,
    plan_path: planPath,
    release_state_path: releaseStatePath
  };
  fs.writeFileSync(outputPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
}

function testRunnerCliAvailability(cwd) {
  const probe = run('runner-cli', ['--version'], cwd);
  return {
    available: probe.status === 0,
    exitCode: probe.status
  };
}

function normalizeWorkflowInputs(rawInputs) {
  const result = [];
  const pushCandidate = (value) => {
    const text = asString(value).trim().replace(/^['"]|['"]$/g, '');
    if (text.length > 0 && text.includes('=')) {
      result.push(text);
    }
  };

  for (const raw of Array.isArray(rawInputs) ? rawInputs : [rawInputs]) {
    if (raw === null || raw === undefined) {
      continue;
    }
    if (Array.isArray(raw)) {
      for (const nested of raw) {
        pushCandidate(nested);
      }
      continue;
    }

    const text = asString(raw);
    if (text.includes(',')) {
      for (const part of text.split(',')) {
        pushCandidate(part);
      }
      continue;
    }
    pushCandidate(text);
  }

  return [...new Set(result)];
}

function invokeWorkflowDispatch({ backend, workflowFile, branch, inputs, runnerCliAvailable, cwd }) {
  const runnerArgs = ['github', 'workflow', 'dispatch', '--workflow', workflowFile, '--ref', branch];
  for (const pair of inputs) {
    runnerArgs.push('--field', pair);
  }

  const ghArgs = ['workflow', 'run', workflowFile, '--ref', branch];
  for (const pair of inputs) {
    ghArgs.push('-f', pair);
  }

  const tryRunnerFirst = backend === 'runner-cli' || (backend === 'auto' && runnerCliAvailable);
  if (tryRunnerFirst) {
    if (!runnerCliAvailable) {
      throw new Error("Dispatch backend 'runner-cli' requested but runner-cli is not available.");
    }

    const runnerDispatch = run('runner-cli', runnerArgs, cwd);
    if (runnerDispatch.status === 0) {
      return {
        method: 'runner-cli',
        exitCode: 0,
        outputPreview: runnerDispatch.output.slice(0, 12)
      };
    }

    if (backend === 'runner-cli') {
      throw new Error(`Workflow dispatch failed via runner-cli: ${runnerDispatch.output.join('\n')}`);
    }
  }

  if (backend === 'gh' || backend === 'auto') {
    const ghDispatch = run('gh', ghArgs, cwd);
    if (ghDispatch.status !== 0) {
      throw new Error(`Workflow dispatch failed via gh: ${ghDispatch.output.join('\n')}`);
    }

    return {
      method: 'gh',
      exitCode: 0,
      outputPreview: ghDispatch.output.slice(0, 12)
    };
  }

  throw new Error(`Unsupported dispatch backend: ${backend}`);
}

function resolveDispatchedRunMeta({ workflowFile, branch, startedUtc, expectedHeadSha, pollSeconds, cwd }) {
  for (let attempt = 1; attempt <= 30; attempt += 1) {
    const listResult = run('gh', [
      'run',
      'list',
      '--workflow',
      workflowFile,
      '--branch',
      branch,
      '--limit',
      '20',
      '--json',
      'databaseId,url,status,conclusion,createdAt,headSha,event'
    ], cwd);

    if (listResult.status === 0) {
      const runs = parseJson(listResult.stdout, 'gh run list');
      const floorUtc = startedUtc.getTime() - 10000;
      const candidates = (Array.isArray(runs) ? runs : [])
        .filter((entry) => asString(entry.event) === 'workflow_dispatch')
        .filter((entry) => Date.parse(asString(entry.createdAt)) >= floorUtc)
        .filter((entry) => expectedHeadSha.length === 0 || asString(entry.headSha) === expectedHeadSha)
        .sort((a, b) => Date.parse(asString(b.createdAt)) - Date.parse(asString(a.createdAt)));

      if (candidates.length > 0) {
        return {
          runId: Number(candidates[0].databaseId),
          url: asString(candidates[0].url),
          headSha: asString(candidates[0].headSha)
        };
      }
    }

    sleep(pollSeconds);
  }

  throw new Error('Unable to correlate dispatched workflow run after 30 attempts.');
}

function ghApiJson(apiPath, cwd) {
  const response = run('gh', ['api', apiPath], cwd);
  if (response.status !== 0) {
    throw new Error(`gh api ${apiPath} failed: ${response.output.join('\n')}`);
  }
  return parseJson(response.stdout, `gh api ${apiPath}`);
}

function parseCli(argv) {
  if (argv.length === 0) {
    throw new Error('control-plane command is required.');
  }
  const command = argv[0];
  let argsJson = '{}';
  for (let i = 1; i < argv.length; i += 1) {
    if (argv[i] === '--args-json') {
      if (i + 1 >= argv.length) {
        throw new Error('--args-json requires a value.');
      }
      argsJson = argv[i + 1];
      i += 1;
    }
  }
  return { command, args: parseJson(argsJson, '--args-json') };
}

function getSnapshot(ownerRepo, runId, cwd) {
  const runPayload = ghApiJson(`repos/${ownerRepo}/actions/runs/${runId}`, cwd);
  const jobsPayload = ghApiJson(`repos/${ownerRepo}/actions/runs/${runId}/jobs?per_page=100`, cwd);
  const artifactsPayload = ghApiJson(`repos/${ownerRepo}/actions/runs/${runId}/artifacts?per_page=100`, cwd);
  return {
    run: runPayload,
    jobs: Array.isArray(jobsPayload.jobs) ? jobsPayload.jobs : [],
    artifacts: Array.isArray(artifactsPayload.artifacts) ? artifactsPayload.artifacts : []
  };
}

function requiredArtifactStatus(artifactNames) {
  const missing = [];
  for (const prefix of REQUIRED_ARTIFACT_PREFIXES) {
    if (!artifactNames.some((name) => asString(name).startsWith(prefix))) {
      missing.push(prefix);
    }
  }
  return {
    missing,
    ok: missing.length === 0
  };
}

function writeGreenRunMetrics(cwd, payload) {
  const outputDir = path.join(cwd, 'artifacts', 'release-metrics');
  ensureDir(outputDir);
  const outputPath = path.join(outputDir, `green-run-${payload.run_id}.json`);
  fs.writeFileSync(outputPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  return outputPath;
}

function loadGreenRunMetrics(metricsDir) {
  if (!fs.existsSync(metricsDir)) {
    return [];
  }

  const entries = [];
  const files = fs
    .readdirSync(metricsDir)
    .filter((name) => /^green-run-.*\.json$/i.test(name));

  for (const fileName of files) {
    const fullPath = path.join(metricsDir, fileName);
    try {
      const parsed = parseJson(fs.readFileSync(fullPath, 'utf8'), `green-run metrics (${fullPath})`);
      const generatedUtc = asString(parsed.generated_utc);
      const generatedMs = Date.parse(generatedUtc);
      const stat = fs.statSync(fullPath);
      entries.push({
        ...parsed,
        __file: fullPath,
        __generated_ms: Number.isFinite(generatedMs) ? generatedMs : stat.mtimeMs
      });
    } catch (error) {
      console.error(`[control-plane] WARNING: skipping invalid metrics file '${fullPath}': ${error.message}`);
    }
  }

  return entries.sort((a, b) => b.__generated_ms - a.__generated_ms);
}

function commandShadowPromotionEvaluate(rawArgs) {
  const cwd = repoRoot();
  process.chdir(cwd);

  const threshold = Math.max(1, asInt(rawArgs.MinConsecutiveGreens, DEFAULT_SHADOW_PROMOTION_MIN_GREENS));
  const metricsDirectoryInput = asString(rawArgs.MetricsDirectory);
  const metricsDirectory = metricsDirectoryInput.length > 0
    ? (path.isAbsolute(metricsDirectoryInput) ? metricsDirectoryInput : path.resolve(cwd, metricsDirectoryInput))
    : path.join(cwd, 'artifacts', 'release-metrics');

  const outputPathInput = asString(rawArgs.OutputPath);
  const outputPath = outputPathInput.length > 0
    ? (path.isAbsolute(outputPathInput) ? outputPathInput : path.resolve(cwd, outputPathInput))
    : path.join(metricsDirectory, 'shadow-promotion-state.json');

  const requiredLaneNames = asStringArray(rawArgs.RequiredLaneNames);
  const shadowLaneNames = asStringArray(rawArgs.ShadowLaneNames);
  const expectedRolloutSignature = asString(rawArgs.RolloutSignature).trim();
  const expectedRunnerPoolSignature = asString(rawArgs.RunnerPoolSignature).trim();

  const metrics = loadGreenRunMetrics(metricsDirectory);
  let consecutiveGreens = 0;
  let resetReason = metrics.length === 0 ? 'no_metrics' : '';
  let baselineRolloutSignature = '';
  let baselineRunnerPoolSignature = '';
  const evaluatedRuns = [];

  for (const metric of metrics) {
    const laneName = asString(metric.lane_name);
    const laneRole = asString(metric.lane_role).toLowerCase();
    const runId = asInt(metric.run_id, 0);
    const isAuthoritative = asBool(metric.is_authoritative_latest_head, false);
    const requiredPassed = asBool(metric.required_lanes_passed, false);
    const gateOutcome = asString(metric.gate_outcome).toLowerCase();
    const conclusion = asString(metric.conclusion).toLowerCase();
    const shadowField = metric.shadow_passed;
    const shadowPassed = (shadowField === null || shadowField === undefined) ? true : asBool(shadowField, false);
    const rolloutSignature = asString(metric.rollout_signature || metric.workflow || '').trim();
    const runnerPoolSignature = asString(metric.runner_pool_signature ||
      (Array.isArray(metric.runner_labels) ? metric.runner_labels.slice().sort().join(',') : '')).trim();

    let qualifies = true;
    let disqualifier = '';

    if (!isAuthoritative) {
      qualifies = false;
      disqualifier = 'non_authoritative_head';
    } else if (!requiredPassed) {
      qualifies = false;
      disqualifier = 'required_lane_failure';
    } else if (!shadowPassed) {
      qualifies = false;
      disqualifier = 'shadow_lane_failure';
    } else if (gateOutcome !== 'go' || conclusion !== 'success') {
      qualifies = false;
      disqualifier = 'run_not_green';
    }

    if (qualifies && requiredLaneNames.length > 0 && laneRole === 'required' && laneName.length > 0) {
      if (!requiredLaneNames.includes(laneName)) {
        qualifies = false;
        disqualifier = 'required_lane_scope_changed';
      }
    }

    if (qualifies && shadowLaneNames.length > 0 && laneRole === 'shadow' && laneName.length > 0) {
      if (!shadowLaneNames.includes(laneName)) {
        qualifies = false;
        disqualifier = 'shadow_lane_scope_changed';
      }
    }

    if (qualifies && expectedRolloutSignature.length > 0 && rolloutSignature.length > 0 && rolloutSignature !== expectedRolloutSignature) {
      qualifies = false;
      disqualifier = 'rollout_signature_changed';
    }

    if (qualifies && expectedRunnerPoolSignature.length > 0 && runnerPoolSignature.length > 0 && runnerPoolSignature !== expectedRunnerPoolSignature) {
      qualifies = false;
      disqualifier = 'runner_pool_changed';
    }

    if (qualifies && consecutiveGreens > 0 && baselineRolloutSignature.length > 0 && rolloutSignature.length > 0 && rolloutSignature !== baselineRolloutSignature) {
      qualifies = false;
      disqualifier = 'rollout_signature_changed';
    }

    if (qualifies && consecutiveGreens > 0 && baselineRunnerPoolSignature.length > 0 && runnerPoolSignature.length > 0 && runnerPoolSignature !== baselineRunnerPoolSignature) {
      qualifies = false;
      disqualifier = 'runner_pool_changed';
    }

    evaluatedRuns.push({
      run_id: runId,
      lane_name: laneName,
      lane_role: laneRole,
      qualifies,
      disqualifier,
      is_authoritative_latest_head: isAuthoritative,
      required_lanes_passed: requiredPassed,
      shadow_passed: shadowPassed,
      gate_outcome: gateOutcome,
      conclusion,
      rollout_signature: rolloutSignature,
      runner_pool_signature: runnerPoolSignature,
      metrics_file: asString(metric.__file),
      generated_utc: asString(metric.generated_utc)
    });

    if (qualifies) {
      if (consecutiveGreens === 0) {
        baselineRolloutSignature = rolloutSignature;
        baselineRunnerPoolSignature = runnerPoolSignature;
      }
      consecutiveGreens += 1;
      if (consecutiveGreens >= threshold) {
        break;
      }
      continue;
    }

    if (resetReason.length === 0) {
      resetReason = disqualifier.length > 0 ? disqualifier : 'unknown_reset';
    }
    break;
  }

  if (consecutiveGreens < threshold && resetReason.length === 0) {
    resetReason = metrics.length === 0 ? 'no_metrics' : 'insufficient_consecutive_greens';
  }

  const state = {
    schema_version: '1.0',
    generated_utc: new Date().toISOString(),
    threshold,
    consecutive_green_count: consecutiveGreens,
    promotion_ready: consecutiveGreens >= threshold,
    reset_reason: resetReason,
    metrics_directory: metricsDirectory,
    required_lane_names: requiredLaneNames,
    shadow_lane_names: shadowLaneNames,
    expected_rollout_signature: expectedRolloutSignature,
    expected_runner_pool_signature: expectedRunnerPoolSignature,
    evaluated_run_count: evaluatedRuns.length,
    evaluated_runs: evaluatedRuns
  };

  ensureDir(path.dirname(outputPath));
  fs.writeFileSync(outputPath, `${JSON.stringify(state, null, 2)}\n`, 'utf8');
  console.log(JSON.stringify(state, null, 2));
}

function commandReleaseMetrics(rawArgs) {
  const cwd = repoRoot();
  process.chdir(cwd);

  const runId = asInt(rawArgs.RunId, 0);
  if (runId <= 0) {
    throw new Error('-RunId is required.');
  }

  const ownerRepo = inferOwnerRepo(rawArgs.OwnerRepo, cwd);
  const snapshot = getSnapshot(ownerRepo, runId, cwd);
  const artifactNames = snapshot.artifacts.map((artifact) => asString(artifact.name));
  const artifactStatus = requiredArtifactStatus(artifactNames);
  const failedJobs = snapshot.jobs.filter((job) => BAD_JOB_CONCLUSIONS.has(asString(job.conclusion)));

  let releaseTag = asString(rawArgs.ReleaseTag);
  if (releaseTag.length === 0) {
    const manifestPath = path.join(cwd, 'manifest.json');
    const manifest = parseJson(fs.readFileSync(manifestPath, 'utf8'), 'manifest.json');
    releaseTag = `v${asString(manifest.version)}`;
  }

  const createdMs = Date.parse(asString(snapshot.run.created_at));
  const updatedMs = Date.parse(asString(snapshot.run.updated_at));
  const durationMinutes = Number.isFinite(createdMs) && Number.isFinite(updatedMs)
    ? Math.max(0, Math.round(((updatedMs - createdMs) / 60000) * 100) / 100)
    : 0;

  const payload = {
    schema_version: '1.0',
    generated_utc: new Date().toISOString(),
    owner_repo: ownerRepo,
    consumer_run_id: runId,
    consumer_run_url: `https://github.com/${ownerRepo}/actions/runs/${runId}`,
    release_tag: releaseTag,
    run_status: asString(snapshot.run.status),
    run_conclusion: asString(snapshot.run.conclusion || 'pending'),
    duration_minutes: durationMinutes,
    failed_job_count: failedJobs.length,
    missing_required_artifact_count: artifactStatus.missing.length,
    gate_outcome: (asString(snapshot.run.status) === 'completed' && asString(snapshot.run.conclusion) === 'success' && failedJobs.length === 0 && artifactStatus.missing.length === 0) ? 'go' : 'no-go',
    rollback_triggered: asBool(rawArgs.RollbackTriggered, false),
    top_failure_causes: failedJobs.slice(0, 3).map((job) => `${asString(job.conclusion)}:1`),
    failed_jobs: failedJobs.map((job) => ({
      name: asString(job.name),
      conclusion: asString(job.conclusion)
    })),
    missing_required_artifacts: artifactStatus.missing
  };

  const outputDirInput = asString(rawArgs.OutputDir);
  const outputDir = outputDirInput.length > 0
    ? (path.isAbsolute(outputDirInput) ? outputDirInput : path.resolve(cwd, outputDirInput))
    : path.join(cwd, 'artifacts', 'release-metrics');
  ensureDir(outputDir);

  const outputPath = path.join(outputDir, `release-metrics-${runId}.json`);
  fs.writeFileSync(outputPath, `${JSON.stringify(payload, null, 2)}\n`, 'utf8');
  console.log(JSON.stringify(payload, null, 2));
}

function commandReleaseWatch(rawArgs) {
  const cwd = repoRoot();
  process.chdir(cwd);

  const runId = asInt(rawArgs.RunId, 0);
  if (runId <= 0) {
    throw new Error('-RunId is required.');
  }

  const ownerRepo = inferOwnerRepo(rawArgs.OwnerRepo, cwd);
  const planPathInput = asString(rawArgs.PlanPath);
  if (planPathInput.length === 0) {
    throw new Error('-PlanPath is required.');
  }
  const planPath = path.isAbsolute(planPathInput) ? planPathInput : path.resolve(cwd, planPathInput);
  if (!fs.existsSync(planPath)) {
    throw new Error(`Plan file not found: ${planPath}`);
  }

  const statePathInput = asString(rawArgs.StatePath);
  const statePath = statePathInput.length > 0
    ? (path.isAbsolute(statePathInput) ? statePathInput : path.resolve(cwd, statePathInput))
    : '';
  if (statePath.length > 0) {
    ensureDir(path.dirname(statePath));
  }

  const pollSeconds = asInt(rawArgs.PollSeconds, 30);
  while (true) {
    const snapshot = getSnapshot(ownerRepo, runId, cwd);
    const artifactNames = snapshot.artifacts.map((artifact) => asString(artifact.name));
    const artifactStatus = requiredArtifactStatus(artifactNames);
    const badJobs = snapshot.jobs.filter((job) => BAD_JOB_CONCLUSIONS.has(asString(job.conclusion)));

    const completed = asString(snapshot.run.status) === 'completed';
    const success = asString(snapshot.run.conclusion) === 'success';
    const noBadJobs = badJobs.length === 0;
    const hasArtifacts = artifactStatus.ok;
    const isGo = completed && success && noBadJobs && hasArtifacts;

    if (statePath.length > 0) {
      const statePayload = {
        schema_version: '1.0',
        generated_utc: new Date().toISOString(),
        owner_repo: ownerRepo,
        run_id: runId,
        run_url: `https://github.com/${ownerRepo}/actions/runs/${runId}`,
        run_status: asString(snapshot.run.status),
        run_conclusion: asString(snapshot.run.conclusion || 'pending'),
        required_artifacts: REQUIRED_ARTIFACT_PREFIXES,
        observed_artifacts: artifactNames,
        missing_required_artifacts: artifactStatus.missing,
        bad_jobs: badJobs.map((job) => ({
          name: asString(job.name),
          status: asString(job.status),
          conclusion: asString(job.conclusion),
          html_url: asString(job.html_url)
        })),
        gate: {
          is_completed: completed,
          is_success: success,
          has_no_bad_jobs: noBadJobs,
          has_required_artifacts: hasArtifacts
        },
        is_go_eligible: isGo,
        plan_path: planPath,
        phase: completed ? 'terminal' : 'monitoring'
      };
      fs.writeFileSync(statePath, `${JSON.stringify(statePayload, null, 2)}\n`, 'utf8');
    }

    if (completed) {
      console.log(JSON.stringify({
        run_id: runId,
        status: asString(snapshot.run.status),
        conclusion: asString(snapshot.run.conclusion),
        failed_or_cancelled: badJobs.length,
        missing_required_artifacts: artifactStatus.missing.length
      }, null, 2));
      return;
    }
    sleep(pollSeconds);
  }
}

function commandAutonomousLoop(rawArgs) {
  const cwd = repoRoot();
  process.chdir(cwd);

  const workflowFile = asString(rawArgs.WorkflowFile || 'windows-linux-vipm-package.yml');
  let branch = asString(rawArgs.Branch);
  if (branch.length === 0) {
    const branchProbe = run('git', ['branch', '--show-current'], cwd);
    if (branchProbe.status !== 0 || branchProbe.stdout.trim().length === 0) {
      throw new Error('Unable to resolve current git branch.');
    }
    branch = branchProbe.stdout.trim();
  }

  const ownerRepo = inferOwnerRepo(rawArgs.OwnerRepo, cwd);
  const pollSeconds = asInt(rawArgs.PollSeconds, 20);
  const maxCycles = asInt(rawArgs.MaxCycles, 0);
  const cycleSleepSeconds = asInt(rawArgs.CycleSleepSeconds, 60);
  const skipLocalTests = asBool(rawArgs.SkipLocalTests, false);

  let cycle = 0;
  while (true) {
    cycle += 1;
    const started = new Date();

    if (!skipLocalTests) {
      const localTests = run('pwsh', ['-NoProfile', '-File', './scripts/Invoke-ContractTests.ps1', '-TestPath', asString(rawArgs.TestPath || './tests/*.Tests.ps1')], cwd);
      if (localTests.status !== 0) {
        if (maxCycles > 0 && cycle >= maxCycles) {
          break;
        }
        sleep(cycleSleepSeconds);
        continue;
      }
    }

    const headProbe = run('git', ['rev-parse', 'HEAD'], cwd);
    const expectedHeadSha = headProbe.status === 0 ? headProbe.stdout.trim() : '';
    const dispatch = run('gh', ['workflow', 'run', workflowFile, '--ref', branch, '-f', 'consumer_ref=develop'], cwd);
    if (dispatch.status !== 0) {
      throw new Error(`Workflow dispatch failed: ${dispatch.output.join('\n')}`);
    }

    let runId = 0;
    for (let attempt = 0; attempt < 30; attempt += 1) {
      const list = run('gh', ['run', 'list', '--workflow', workflowFile, '--branch', branch, '--limit', '20', '--json', 'databaseId,createdAt,headSha,event,url'], cwd);
      if (list.status === 0) {
        const runs = parseJson(list.stdout, 'gh run list');
        const floor = started.getTime() - 10000;
        const match = (Array.isArray(runs) ? runs : [])
          .filter((item) => asString(item.event) === 'workflow_dispatch')
          .filter((item) => Date.parse(asString(item.createdAt)) >= floor)
          .find((item) => expectedHeadSha.length === 0 || asString(item.headSha) === expectedHeadSha);
        if (match) {
          runId = Number(match.databaseId);
          break;
        }
      }
      sleep(pollSeconds);
    }

    if (runId <= 0) {
      throw new Error('Unable to correlate dispatched workflow run.');
    }

    while (true) {
      const snapshot = getSnapshot(ownerRepo, runId, cwd);
      if (asString(snapshot.run.status) === 'completed') {
        const badJobs = snapshot.jobs.filter((job) => BAD_JOB_CONCLUSIONS.has(asString(job.conclusion)));
        const succeeded = asString(snapshot.run.conclusion) === 'success' && badJobs.length === 0;
        if (succeeded) {
          const payload = {
            schema_version: '1.0',
            generated_utc: new Date().toISOString(),
            owner_repo: ownerRepo,
            workflow: workflowFile,
            run_id: runId,
            run_attempt: asInt(snapshot.run.run_attempt, 1),
            head_sha: asString(snapshot.run.head_sha),
            expected_head_sha: expectedHeadSha,
            is_authoritative_latest_head: expectedHeadSha.length > 0 ? expectedHeadSha === asString(snapshot.run.head_sha) : null,
            status: asString(snapshot.run.status),
            conclusion: asString(snapshot.run.conclusion),
            gate_outcome: 'go',
            required_lanes_passed: true,
            shadow_passed: null,
            queue_seconds: null,
            duration_seconds: null,
            job_durations: snapshot.jobs.map((job) => ({
              name: asString(job.name),
              conclusion: asString(job.conclusion),
              status: asString(job.status)
            })),
            runner_labels: [],
            artifact_contract_hashes: snapshot.artifacts.map((artifact) => ({
              name: asString(artifact.name),
              id: Number(artifact.id),
              size_in_bytes: Number(artifact.size_in_bytes)
            }))
          };
          const metricsPath = writeGreenRunMetrics(cwd, payload);
          console.log(JSON.stringify({ cycle, run_id: runId, conclusion: 'success', green_run_metrics_path: metricsPath }, null, 2));
        } else {
          console.log(JSON.stringify({ cycle, run_id: runId, conclusion: asString(snapshot.run.conclusion), failed_jobs: badJobs.length }, null, 2));
        }
        break;
      }
      sleep(pollSeconds);
    }

    if (maxCycles > 0 && cycle >= maxCycles) {
      break;
    }
    sleep(cycleSleepSeconds);
  }
}

function commandReleaseOrchestrator(rawArgs) {
  const cwd = repoRoot();
  process.chdir(cwd);
  const runId = asInt(rawArgs.RunId, 0);
  if (runId <= 0) {
    throw new Error('-RunId is required.');
  }
  const planPath = asString(rawArgs.PlanPath);
  if (planPath.length === 0) {
    throw new Error('-PlanPath is required.');
  }

  const resolvedPlanPath = path.isAbsolute(planPath) ? planPath : path.resolve(cwd, planPath);
  const ownerRepo = inferOwnerRepo(rawArgs.OwnerRepo, cwd);
  const outputDirInput = asString(rawArgs.OutputDir);
  const outputDir = outputDirInput.length > 0 ? (path.isAbsolute(outputDirInput) ? outputDirInput : path.resolve(cwd, outputDirInput)) : path.join(cwd, 'artifacts', 'release-state');
  ensureDir(outputDir);
  const statePath = path.join(outputDir, `release-state-${runId}.json`);
  const dispatchPath = path.join(outputDir, `dispatch-result-${runId}.json`);

  commandReleaseWatch({
    RunId: runId,
    PlanPath: resolvedPlanPath,
    OwnerRepo: ownerRepo,
    StatePath: statePath,
    PollSeconds: asInt(rawArgs.PollSeconds, 30)
  });

  const snapshot = getSnapshot(ownerRepo, runId, cwd);
  const artifactStatus = requiredArtifactStatus(snapshot.artifacts.map((artifact) => asString(artifact.name)));
  const badJobs = snapshot.jobs.filter((job) => BAD_JOB_CONCLUSIONS.has(asString(job.conclusion)));
  const isGo = asString(snapshot.run.status) === 'completed' && asString(snapshot.run.conclusion) === 'success' && badJobs.length === 0 && artifactStatus.ok;

  const manifest = parseJson(fs.readFileSync(path.join(cwd, 'manifest.json'), 'utf8'), 'manifest.json');
  const releaseTag = asString(rawArgs.ReleaseTag || `v${asString(manifest.version)}`);
  const consumerRef = asString(snapshot.run.head_branch);
  const consumerSha = asString(snapshot.run.head_sha);

  if (!isGo) {
    writeDispatchResult({ path: dispatchPath, status: 'no-go', runId, releaseTag, ownerRepo, consumerRef, consumerSha, skillRepo: null, workflowRef: null, planPath: resolvedPlanPath, releaseStatePath: statePath, method: null });
    console.log(JSON.stringify({ status: 'no-go', run_id: runId, dispatch_result_path: dispatchPath }, null, 2));
    process.exitCode = 2;
    return;
  }

  if (asBool(rawArgs.DryRun, false)) {
    writeDispatchResult({ path: dispatchPath, status: 'go-dry-run', runId, releaseTag, ownerRepo, consumerRef, consumerSha, skillRepo: ownerRepo, workflowRef: 'main', planPath: resolvedPlanPath, releaseStatePath: statePath, method: null });
    console.log(JSON.stringify({ status: 'go-dry-run', run_id: runId, dispatch_result_path: dispatchPath }, null, 2));
    return;
  }

  const dispatch = run('gh', ['workflow', 'run', 'release-skill-layer.yml', '--repo', ownerRepo, '--ref', inferOrchestratorRef(cwd), '-f', `release_tag=${releaseTag}`, '-f', `consumer_repo=${ownerRepo}`, '-f', `consumer_ref=${consumerRef}`, '-f', `consumer_sha=${consumerSha}`], cwd);
  if (dispatch.status !== 0) {
    throw new Error(`Dispatch failed: ${dispatch.output.join('\n')}`);
  }
  writeDispatchResult({ path: dispatchPath, status: 'dispatched', runId, releaseTag, ownerRepo, consumerRef, consumerSha, skillRepo: ownerRepo, workflowRef: inferOrchestratorRef(cwd), planPath: resolvedPlanPath, releaseStatePath: statePath, method: 'gh' });
  console.log(JSON.stringify({ status: 'dispatched', run_id: runId, dispatch_result_path: dispatchPath }, null, 2));
}

function commandSelfCheck() {
  console.log(JSON.stringify({
    status: 'ok',
    generated_utc: new Date().toISOString(),
    required_artifact_prefixes: REQUIRED_ARTIFACT_PREFIXES,
    shadow_promotion_min_greens: DEFAULT_SHADOW_PROMOTION_MIN_GREENS
  }, null, 2));
}

function main() {
  const parsed = parseCli(process.argv.slice(2));
  switch (parsed.command) {
    case 'autonomous-loop':
      commandAutonomousLoop(parsed.args);
      return;
    case 'release-watch':
      commandReleaseWatch(parsed.args);
      return;
    case 'release-metrics':
      commandReleaseMetrics(parsed.args);
      return;
    case 'release-orchestrator':
      commandReleaseOrchestrator(parsed.args);
      return;
    case 'shadow-promotion-evaluate':
      commandShadowPromotionEvaluate(parsed.args);
      return;
    case 'self-check':
      commandSelfCheck();
      return;
    default:
      throw new Error(`Unsupported control-plane command: ${parsed.command}`);
  }
}

try {
  main();
} catch (error) {
  console.error(`[control-plane] ${error.message}`);
  process.exitCode = 1;
}
