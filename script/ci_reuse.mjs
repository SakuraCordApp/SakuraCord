import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { appendFileSync, existsSync, readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const workflowPath = '.github/workflows/ci.yml';
const releaseTag = /^v\d+\.\d+\.\d+(?:-Beta-\d+)?$/;

export function trustedRun(run, repository, configuration = 'debug') {
  const branch = configuration === 'release'
    ? releaseTag.test(run.head_branch)
    : ['main', 'nightly'].includes(run.head_branch);
  return branch && run.event === 'push' && run.status === 'completed'
    && run.conclusion === 'success' && run.path === workflowPath
    && run.repository?.full_name === repository
    && run.head_repository?.full_name === repository;
}

export function fullValidation(jobs) {
  return jobs.some(job => job.name === 'build' && job.conclusion === 'success'
    && ['Verify checked-out commit', 'Build and test'].every(name =>
      job.steps?.some(step => step.name === name
        && step.status === 'completed' && step.conclusion === 'success')));
}

export async function findValidation({ api, repository, sha, currentRun }) {
  const { workflow_runs: runs } = await api(`repos/${repository}/actions/workflows/ci.yml/runs?event=push&status=success&head_sha=${sha}&per_page=100`);
  for (const run of runs) {
    if (String(run.id) === String(currentRun) || run.head_sha !== sha
        || !trustedRun(run, repository)) continue;
    const { jobs } = await api(`repos/${repository}/actions/runs/${run.id}/attempts/${run.run_attempt}/jobs?per_page=100`);
    if (fullValidation(jobs)) return run;
  }
  return null;
}

export async function findCache({ api, repository, key, configuration, currentRun, isAncestor }) {
  const { artifacts } = await api(`repos/${repository}/actions/artifacts?name=${encodeURIComponent(key)}&per_page=100`);
  // Bounded lookup: a cache miss always falls back to an ordinary build.
  for (const artifact of artifacts.slice(0, 20)) {
    if (artifact.expired || artifact.name !== key || !artifact.workflow_run
        || String(artifact.workflow_run.id) === String(currentRun)) continue;
    const run = await api(`repos/${repository}/actions/runs/${artifact.workflow_run.id}`);
    if (!trustedRun(run, repository, configuration)
        || artifact.workflow_run.head_sha !== run.head_sha
        || !await isAncestor(run.head_sha)) continue;
    return { artifact, run };
  }
  return null;
}

function command(program, args) {
  return execFileSync(program, args, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
}

function api(endpoint) {
  return JSON.parse(command('gh', ['api', endpoint]));
}

function output(name, value) {
  if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `${name}=${value}\n`);
  console.log(`${name}=${value}`);
}

function cacheKey(configuration) {
  const hash = createHash('sha256');
  const add = value => hash.update(value).update('\0');
  add('swiftpm-artifacts-v1');
  add(configuration);
  add(process.cwd()); // Swift build records contain absolute paths.
  for (const [program, args] of [
    ['sw_vers', []], ['xcodebuild', ['-version']], ['swift', ['--version']],
    ['xcrun', ['--sdk', 'macosx', '--show-sdk-version']], ['uname', ['-m']],
  ]) add(command(program, args));
  const files = command('git', ['ls-files', '-z']).split('\0').filter(path =>
    /(^|\/)Package\.(swift|resolved)$/.test(path)
    || /^script\/(ci|ci_reuse|test|run_test_diagnostics|runtime|build_and_run|package_dmg)\./.test(path)
    || path === workflowPath);
  for (const path of files.sort()) {
    add(path);
    add(readFileSync(path));
  }
  return `swiftpm-v1-${configuration}-${hash.digest('hex')}`;
}

async function main() {
  const [mode, configuration] = process.argv.slice(2);
  const repository = process.env.GITHUB_REPOSITORY;
  const currentRun = process.env.GITHUB_RUN_ID;
  if (!repository || !currentRun) throw new Error('Run this helper inside GitHub Actions.');
  if (mode === 'validation') {
    let run = null;
    const release = process.env.GITHUB_EVENT_NAME === 'workflow_dispatch'
      || (process.env.GITHUB_EVENT_NAME === 'push' && process.env.GITHUB_REF?.startsWith('refs/tags/v'));
    if (release) {
      try {
        const sha = command('git', ['rev-parse', 'HEAD']);
        // A repair using a changed workflow must run validation again.
        const currentPolicy = command('git', ['rev-parse', `${process.env.GITHUB_WORKFLOW_SHA}:${workflowPath}`]);
        const sourcePolicy = command('git', ['rev-parse', `HEAD:${workflowPath}`]);
        if (currentPolicy === sourcePolicy) {
          run = await findValidation({ api, repository, sha, currentRun });
        }
      } catch {
        console.log('Validation lookup unavailable; running the complete CI suite.');
      }
    }
    output('reused', Boolean(run));
    if (run) console.log(`Reusing full validation: ${run.html_url}`);
    return;
  }
  if (!['debug', 'release'].includes(configuration)) throw new Error('Expected debug or release configuration.');
  const archive = join(process.env.RUNNER_TEMP, `swiftpm-${configuration}.tar`);
  if (mode === 'archive') {
    const paths = ['App/.build/out'];
    if (configuration === 'debug') {
      for (const name of ['SakuraCordModels', 'DiscordProtocol', 'SakuraCordPersistence',
        'MessageRendering', 'MediaPipeline', 'SakuraCordPluginSDK']) {
        paths.push(`Packages/${name}/.build/out`);
      }
    }
    // Archive only compiler outputs, never credentials, app state, or signed dist assets.
    const present = paths.filter(path => existsSync(path));
    if (present.length !== paths.length) throw new Error('Expected SwiftPM build output is missing.');
    command('tar', ['-cf', archive, ...present]);
    return;
  }
  if (mode !== 'restore') throw new Error('Expected validation, restore, or archive.');
  const key = cacheKey(configuration);
  output('key', key);
  try {
    const cached = await findCache({ api, repository, key, configuration, currentRun,
      isAncestor: sha => {
        try { command('git', ['merge-base', '--is-ancestor', sha, 'HEAD']); return true; }
        catch { return false; }
      } });
    if (!cached) {
      console.log('No compatible build artifact; compiling from source.');
      return;
    }
    const directory = join(process.env.RUNNER_TEMP, `restore-${configuration}`);
    command('gh', ['run', 'download', String(cached.run.id), '--repo', repository,
      '--name', key, '--dir', directory]);
    command('tar', ['-xf', join(directory, `swiftpm-${configuration}.tar`)]);
    console.log(`Restored ${configuration} compiler outputs from ${cached.run.html_url}`);
  } catch {
    console.log('Build artifact unavailable; continuing with a source build.');
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { console.error(error.message); process.exitCode = 1; });
}
