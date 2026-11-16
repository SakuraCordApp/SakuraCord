#!/usr/bin/env node
// Trusted publication control. No PR checkout, dependency install, or artifact executable is run.
import { createHash, createPrivateKey, createPublicKey, sign, verify } from 'node:crypto';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

export const SOURCE = 'SakuraCordApp/SakuraCord';
export const DISTRIBUTION = 'SakuraCordApp/Builds';
const scriptRoot = path.dirname(fileURLToPath(import.meta.url));
const check = (condition, message) => { if (!condition) throw new Error(message); };
const sha = value => typeof value === 'string' && /^[a-f0-9]{40}$/.test(value);
const integer = value => Number.isSafeInteger(value) && value > 0;
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const json = value => `${JSON.stringify(value, null, 2)}\n`;
const xml = value => String(value).replace(/[<>&"']/g, ch => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;', "'": '&apos;' }[ch]));
const python = (...args) => execFileSync('python3', ['-I', path.join(scriptRoot, 'pr_build_archive.py'), ...args], { encoding: 'utf8', maxBuffer: 1024 * 1024 });

async function api(repo, endpoint, { token = process.env.GH_TOKEN, method = 'GET', body } = {}) {
  const response = await fetch(`https://api.github.com/repos/${repo}/${endpoint}`, {
    method, headers: { Accept: 'application/vnd.github+json', Authorization: `Bearer ${token}`,
      'X-GitHub-Api-Version': '2022-11-28', ...(body ? { 'Content-Type': 'application/json' } : {}) },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  if (response.status === 404) return null;
  check(response.ok, `GitHub ${method} ${endpoint}: ${response.status}`);
  return response.status === 204 ? null : response.json();
}

async function pages(repo, endpoint, key, options = {}, request = api) {
  const result = [];
  for (let page = 1; ; page++) {
    const data = await request(repo, `${endpoint}${endpoint.includes('?') ? '&' : '?'}per_page=100&page=${page}`, options);
    check(data, `Missing ${endpoint}`);
    const items = key ? data[key] : data;
    result.push(...items);
    if (items.length < 100) return result;
  }
}

export function validateOrigin(run, artifact, metadata, workflowID) {
  check(run.repository?.full_name === SOURCE && run.workflow_id === workflowID
    && run.path === '.github/workflows/ci.yml' && run.event === 'pull_request'
    && run.status === 'completed' && run.conclusion === 'success', 'Not a successful canonical PR CI run');
  check(integer(metadata.runID) && integer(metadata.runAttempt) && integer(metadata.pullRequest)
    && metadata.runID <= 9999999999999 && metadata.runAttempt <= 999
    && metadata.runID === run.id && metadata.runAttempt === run.run_attempt, 'Run/attempt mismatch');
  check(artifact.name === `pr-build-${run.id}-${run.run_attempt}` && !artifact.expired
    && artifact.workflow_run?.id === run.id
    && artifact.workflow_run.head_sha === run.head_sha
    && artifact.workflow_run.head_repository_id === run.head_repository?.id, 'Artifact provenance mismatch');
  const created = Date.parse(artifact.created_at);
  const started = Date.parse(run.run_started_at);
  const completed = Date.parse(run.updated_at);
  check(Number.isFinite(created) && Number.isFinite(started) && Number.isFinite(completed)
    && created >= started && created <= completed, 'Artifact was not created during this run attempt');
  const pr = run.pull_requests?.find(item => item.number === metadata.pullRequest);
  check(pr && sha(metadata.headSHA) && sha(metadata.baseSHA) && sha(metadata.builtSHA)
    && run.head_sha === metadata.headSHA && pr.head.repo.id === run.head_repository.id,
  'PR commit provenance mismatch');
  const fork = pr.head.repo.id !== run.repository.id;
  check(metadata.schemaVersion === 1 && metadata.configuration === 'debug'
    && metadata.architecture === 'arm64'
    && metadata.id === `pr-${pr.number}-run-${run.id}-attempt-${run.run_attempt}`, 'Invalid build identity');
  return { ...metadata, fork };
}

export async function resolvePullRequest(run, metadata, request = api) {
  check(integer(metadata.pullRequest), 'Invalid PR number');
  const pr = await request(SOURCE, `pulls/${metadata.pullRequest}`);
  check(pr?.number === metadata.pullRequest && pr.head?.repo?.id === run.head_repository?.id,
    'PR repository provenance mismatch');
  // Fork runs can omit PR summaries, and the commit-to-PR endpoint can return
  // nothing even for the current fork head. Bind directly to the PR's commit
  // history when GitHub did not record the association on the run.
  if (!run.pull_requests?.some(item => item.number === pr.number)) {
    check(pr.head.sha === run.head_sha ||
      (await pages(SOURCE, `pulls/${pr.number}/commits`, null, {}, request)).some(commit => commit.sha === run.head_sha),
    'CI commit is not part of the pull request');
  }
  return pr;
}

export async function validateBuiltCommit(context, pr, request = api) {
  const commit = await request(SOURCE, `commits/${context.builtSHA}`);
  check(commit?.sha === context.builtSHA, 'Built commit is unavailable');
  if (context.builtSHA === context.headSHA) return commit;
  check(commit.parents?.length === 2 && commit.parents[1].sha === context.headSHA,
    'Built commit is not a merge of the recorded PR head');
  const mergeBase = commit.parents[0].sha;
  if (mergeBase !== context.baseSHA) {
    // GitHub can refresh refs/pull/N/merge after constructing the PR event.
    // Accept only a forward base update that is still on the canonical target.
    check(pr.base?.repo?.full_name === SOURCE && typeof pr.base.ref === 'string' && pr.base.ref.length > 0,
      'Invalid PR base repository');
    const target = await request(SOURCE, `branches/${encodeURIComponent(pr.base.ref)}`);
    check(sha(target?.commit?.sha), 'PR target branch is unavailable');
    for (const [base, head] of [[context.baseSHA, mergeBase], [mergeBase, target.commit.sha]]) {
      const comparison = await request(SOURCE, `compare/${base}...${head}`);
      check(comparison && ['ahead', 'identical'].includes(comparison.status)
        && comparison.merge_base_commit?.sha === base,
      'Built merge base is not a forward update on the PR target branch');
    }
  }
  return commit;
}

export async function verifyCIJobs(runID, attempt, request = api,
  pause = ms => new Promise(resolve => setTimeout(resolve, ms))) {
  for (let poll = 0; poll < 20; poll++) {
    const jobs = await pages(SOURCE, `actions/runs/${runID}/attempts/${attempt}/jobs`, 'jobs', {}, request);
    const builds = jobs.filter(job => /^build \(.+\)$/.test(job.name));
    let incomplete = !['build (packages)', 'build (app)'].every(name => builds.some(job => job.name === name));
    for (const job of builds) {
      check(job.run_id === runID && job.run_attempt === attempt, 'CI job run/attempt mismatch');
      check(job.conclusion == null || job.conclusion === 'success', `CI job did not pass: ${job.name}`);
      incomplete ||= job.conclusion !== 'success';
      const required = ['Build and test', ...(job.name === 'build (app)' ?
        ['Package downloadable pull request app and matching symbols', 'Upload pull request build'] : [])];
      for (const name of required) {
        const step = job.steps?.find(step => step.name === name);
        check(step?.conclusion == null || step.conclusion === 'success', `CI step did not pass: ${job.name}: ${name}`);
        incomplete ||= step?.conclusion !== 'success';
      }
    }
    if (!incomplete) return;
    check(poll < 19, 'GitHub CI step records are still incomplete; retry publication when they are available');
    console.log('Waiting for GitHub to finish reporting CI job steps (30 seconds)...');
    await pause(30_000);
  }
}

async function prepare(directory) {
  const runID = Number(process.env.PR_BUILD_RUN_ID);
  const attempt = Number(process.env.PR_BUILD_RUN_ATTEMPT);
  check(integer(runID) && integer(attempt), 'Run ID and attempt must be positive integers');
  const run = await api(SOURCE, `actions/runs/${runID}/attempts/${attempt}`);
  check(run, 'Run attempt is unavailable');
  const workflow = await api(SOURCE, 'actions/workflows/ci.yml');
  const artifacts = await pages(SOURCE, `actions/runs/${runID}/artifacts`, 'artifacts');
  const candidates = artifacts.filter(item => item.name === `pr-build-${runID}-${attempt}`);
  check(candidates.length === 1 && !candidates[0].expired, 'Exactly one retained artifact for this attempt is required');
  const artifact = candidates[0];
  check(artifact.size_in_bytes <= 4 * 1024 ** 3, 'Artifact exceeds size limit');
  // GitHub redirects this authenticated request to a short-lived blob URL; fetch strips
  // Authorization when following cross-origin redirects.
  const response = await fetch(`https://api.github.com/repos/${SOURCE}/actions/artifacts/${artifact.id}/zip`,
    { headers: { Authorization: `Bearer ${process.env.GH_TOKEN}` } });
  check(response.ok, 'Artifact download failed');
  const bytes = Buffer.from(await response.arrayBuffer());
  check(artifact.digest === `sha256:${digest(bytes)}`, 'GitHub artifact digest mismatch');
  await mkdir(directory, { recursive: true });
  await writeFile(path.join(directory, 'artifact.zip'), bytes);
  python('unwrap', path.join(directory, 'artifact.zip'), directory);
  const metadata = JSON.parse(await readFile(path.join(directory, 'build.json'), 'utf8'));
  const pr = await resolvePullRequest(run, metadata);
  const context = validateOrigin({ ...run, pull_requests: [pr] }, artifact, metadata, workflow.id);
  const commit = await validateBuiltCommit(context, pr);
  const headCommit = context.builtSHA === context.headSHA ? commit : await api(SOURCE, `commits/${context.headSHA}`);
  check(headCommit?.sha === context.headSHA && typeof headCommit.commit?.message === 'string',
    'PR head commit message is unavailable');
  context.commitSubject = [...headCommit.commit.message.split(/\r?\n/, 1)[0].trim()].slice(0, 500).join('');
  check(context.commitSubject.length > 0, 'PR head commit subject is empty');
  await verifyCIJobs(runID, attempt);
  context.title = pr.title;
  context.createdAt = artifact.created_at;
  context.artifactID = artifact.id;
  context.artifactDigest = artifact.digest;
  await writeFile(path.join(directory, 'context.json'), json(context));
  const info = JSON.parse(python('validate', directory, path.join(directory, 'context.json')));
  await writeFile(path.join(directory, 'context.json'), json({ ...context, ...info }));
  if (process.env.GITHUB_OUTPUT) await writeFile(process.env.GITHUB_OUTPUT, 'ready=true\n', { flag: 'a' });
}

export function signingKey(seed, expectedPublicKey) {
  const data = Buffer.from(seed ?? '', 'base64');
  check(data.length === 32, 'Expected an Ed25519 seed');
  const key = createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), data]), format: 'der', type: 'pkcs8' });
  const publicKey = createPublicKey(key);
  check(publicKey.export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64') === expectedPublicKey,
    'Sparkle signing key does not match embedded public key');
  return key;
}

export function signedAppcast(build, archive, key) {
  const signature = sign(null, archive, key).toString('base64');
  check(verify(null, archive, createPublicKey(key), Buffer.from(signature, 'base64')), 'Archive signature verification failed');
  const content = Buffer.from(`<?xml version="1.0" encoding="utf-8"?>\n<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>SakuraCord PR builds</title><item><title>${xml(build.title)}</title><description>${xml(`PR #${build.pullRequest} · ${build.headSHA} · ${build.id}`)}</description><pubDate>${new Date(build.createdAt).toUTCString()}</pubDate><sparkle:version>${xml(build.buildVersion)}</sparkle:version><sparkle:shortVersionString>${xml(build.version)}</sparkle:shortVersionString><sparkle:minimumSystemVersion>27.0</sparkle:minimumSystemVersion><enclosure url="${xml(build.archiveURL)}" sparkle:edSignature="${signature}" length="${archive.length}" type="application/octet-stream"/></item></channel></rss>\n`);
  const feedSignature = sign(null, content, key).toString('base64');
  // Sparkle 2.9.6 common_cli/Signing.swift signAppcast and SPUExtractSignedFeed.m.
  return Buffer.concat([content, Buffer.from(`<!-- sparkle-signatures:\nedSignature: ${feedSignature}\nlength: ${content.length}\n-->\n`)]);
}

async function publicBytes(url) {
  const response = await fetch(url, { cache: 'no-store' });
  check(response.ok, `Public download failed: ${response.status}`);
  return Buffer.from(await response.arrayBuffer());
}

function downloadAsset(asset, token) {
  return fetch(asset.url, { headers: { Authorization: `Bearer ${token}`, Accept: 'application/octet-stream' } });
}

async function upload(release, name, bytes, token, replace = false) {
  const assets = await pages(DISTRIBUTION, `releases/${release.id}/assets`, null, { token });
  const existing = assets.find(asset => asset.name === name);
  if (existing) {
    if (!replace) {
      const response = await downloadAsset(existing, token);
      check(response.ok && digest(Buffer.from(await response.arrayBuffer())) === digest(bytes), `Refusing to replace immutable asset ${name}`);
      return;
    }
    if (existing.state === 'uploaded') {
      const response = await downloadAsset(existing, token);
      check(response.ok, `Could not read existing mutable asset ${name}`);
      if (digest(Buffer.from(await response.arrayBuffer())) === digest(bytes)) return;
    }
    await api(DISTRIBUTION, `releases/assets/${existing.id}`, { method: 'DELETE', token });
  }
  const url = `${release.upload_url.replace(/\{.*$/, '')}?name=${encodeURIComponent(name)}`;
  const response = await fetch(url, { method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/octet-stream' }, body: bytes });
  check(response.ok, `Asset upload failed: ${name} (${response.status})`);
}

async function publishDraft(release, token) {
  if (release.draft) await api(DISTRIBUTION, `releases/${release.id}`, { token, method: 'PATCH', body: { draft: false, make_latest: 'false' } });
}

// Replaces a mutable asset, publishes its release, and checks the public download.
async function uploadVerified(tag, name, bytes, token, failure) {
  const release = await distributionRelease(tag, token);
  await upload(release, name, bytes, token, true);
  await publishDraft(release, token);
  check(digest(await publicBytes(`https://github.com/${DISTRIBUTION}/releases/download/${tag}/${name}`)) === digest(bytes), failure);
}

export async function distributionRelease(tag, token, request = api) {
  let release = await request(DISTRIBUTION, `releases/tags/${tag}`, { token });
  if (!release) {
    // The tag endpoint only finds published releases. Resume an interrupted
    // draft by its pending tag, preserving its first manifest and uploaded assets.
    const drafts = (await pages(DISTRIBUTION, 'releases', null, { token }, request))
      .filter(item => item.draft && item.tag_name === tag);
    check(drafts.length <= 1, `Ambiguous draft releases for ${tag}`);
    release = drafts[0];
  }
  if (!release) release = await request(DISTRIBUTION, 'releases', { method: 'POST', token,
    body: { tag_name: tag, name: tag === 'pr-builds' ? 'Pull request build catalog' : tag,
      body: 'Experimental builds. Review the source pull request before installing. Ad-hoc signed; not notarized.',
      draft: true, prerelease: true, make_latest: 'false' } });
  check(release && release.prerelease, 'Unexpected distribution release');
  return release;
}

const newestRunFirst = (a, b) => b.runID - a.runID || b.runAttempt - a.runAttempt;

export function mergeCatalog(catalog, build) {
  check(catalog.schemaVersion === 1 && Array.isArray(catalog.builds), 'Invalid existing catalog');
  const existing = catalog.builds.find(item => item.id === build.id);
  check(!existing || JSON.stringify(existing) === JSON.stringify(build), 'Conflicting immutable catalog entry');
  return { schemaVersion: 1, builds: [...catalog.builds.filter(item => item.id !== build.id), build].sort(newestRunFirst) };
}

export function latestBuildsByPullRequest(catalog) {
  const latest = new Map();
  for (const build of catalog.builds) {
    const previous = latest.get(build.pullRequest);
    if (!previous || newestRunFirst(build, previous) < 0) {
      latest.set(build.pullRequest, build);
    }
  }
  return [...latest.values()];
}

export async function openPullRequestCatalog(catalog, request = api) {
  const open = new Set((await pages(SOURCE, 'pulls?state=open', null, {}, request)).map(pr => pr.number));
  return { ...catalog, builds: catalog.builds.filter(build => open.has(build.pullRequest)) };
}

export async function discardFailedDraftUploads(release, token, request = api) {
  if (!release.draft) return;
  for (const asset of await pages(DISTRIBUTION, `releases/${release.id}/assets`, null, { token }, request)) {
    // A failed GitHub upload may leave an empty reservation, not uploaded bytes.
    // Never discard a completed asset or alter an already published release.
    if (asset.state === 'starter' && asset.size === 0) {
      await request(DISTRIBUTION, `releases/assets/${asset.id}`, { method: 'DELETE', token });
    }
  }
}

async function publish(directory) {
  const context = JSON.parse(await readFile(path.join(directory, 'context.json'), 'utf8'));
  const info = JSON.parse(python('validate', directory, path.join(directory, 'context.json')));
  const archive = await readFile(path.join(directory, 'SakuraCord.app.zip'));
  const symbols = await readFile(path.join(directory, 'SakuraCord.dSYM.zip'));
  const token = process.env.PR_BUILDS_TOKEN;
  check(token, 'Distribution repository token is required');
  const key = signingKey(process.env.SPARKLE_ED_PRIVATE_KEY, process.env.SPARKLE_ED_PUBLIC_KEY);
  const prefix = `https://github.com/${DISTRIBUTION}/releases/download/${context.id}`;
  let build = { ...context, ...info, archiveURL: `${prefix}/SakuraCord.app.zip`, symbolsURL: `${prefix}/SakuraCord.dSYM.zip`,
    appcastURL: `${prefix}/appcast.xml`, sha256: digest(archive), symbolsSHA256: digest(symbols) };
  const release = await distributionRelease(build.id, token);
  await discardFailedDraftUploads(release, token);
  const existingAssets = await pages(DISTRIBUTION, `releases/${release.id}/assets`, null, { token });
  const existingManifest = existingAssets.find(asset => asset.name === 'build.json');
  if (existingManifest) {
    const response = await downloadAsset(existingManifest, token);
    check(response.ok, 'Could not read existing immutable manifest');
    const existing = await response.json();
    // A PR title can change between retries. Preserve its first published snapshot.
    check(JSON.stringify({ ...build, title: existing.title }) === JSON.stringify(existing),
      'Refusing to change immutable build identity or bytes');
    build = existing;
  }
  const feed = signedAppcast(build, archive, key);
  // Record the metadata snapshot first, while the release is still a draft.
  for (const [name, bytes] of [['build.json', Buffer.from(json(build))], ['SakuraCord.app.zip', archive], ['SakuraCord.dSYM.zip', symbols], ['appcast.xml', feed]]) {
    await upload(release, name, bytes, token);
  }
  await publishDraft(release, token);
  // Verify availability before advertising a target in the catalog.
  for (const [url, bytes] of [[build.archiveURL, archive], [build.symbolsURL, symbols], [build.appcastURL, feed]]) {
    check(digest(await publicBytes(url)) === digest(bytes), 'Published bytes differ');
  }
  await rebuildCatalog(token);
}

async function rebuildCatalog(token = process.env.PR_BUILDS_TOKEN) {
  check(token, 'Distribution repository token is required');
  const releases = await pages(DISTRIBUTION, 'releases', null, { token });
  let catalog = { schemaVersion: 1, builds: [] };
  for (const release of releases) {
    if (release.draft || !/^pr-\d+-run-\d+-attempt-\d+$/.test(release.tag_name)) continue;
    const manifest = release.assets.find(asset => asset.name === 'build.json');
    check(manifest, `Published build ${release.tag_name} is missing its manifest`);
    const build = JSON.parse(await publicBytes(manifest.browser_download_url));
    check(build.id === release.tag_name, 'Manifest identity mismatch');
    for (const name of ['SakuraCord.app.zip', 'SakuraCord.dSYM.zip', 'appcast.xml']) {
      check(release.assets.some(asset => asset.name === name), `Published build missing ${name}`);
    }
    catalog = mergeCatalog(catalog, build);
  }
  // Tracks follow the newest retained build, even when an older run is retried.
  // Copy its signed immutable feed verbatim: catalog recovery needs no signing key.
  for (const build of latestBuildsByPullRequest(catalog)) {
    const tag = `pr-${build.pullRequest}`;
    const feed = await publicBytes(`https://github.com/${DISTRIBUTION}/releases/download/${build.id}/appcast.xml`);
    await uploadVerified(tag, 'appcast.xml', feed, token, 'PR track verification failed');
  }
  // Discovery follows current PR state; immutable downloads and update tracks
  // remain available to people who already installed a closed PR's build.
  catalog = await openPullRequestCatalog(catalog);
  await uploadVerified('pr-builds', 'catalog.json', Buffer.from(json(catalog)), token, 'Catalog verification failed');
  console.log(`Published catalog with ${catalog.builds.length} builds from open pull requests.`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [command, directory = 'pr-publication'] = process.argv.slice(2);
  try {
    if (command === 'prepare') await prepare(directory);
    else if (command === 'publish') await publish(directory);
    else if (command === 'rebuild-catalog') await rebuildCatalog();
    else throw new Error('Expected prepare, publish, or rebuild-catalog');
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
