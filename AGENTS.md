# SakuraCord agent guidance

This file applies to the entire repository.

SakuraCord is an interactive native macOS Discord client. It is not a self-bot,
spam tool, scraper, or unattended account-automation system. User-visible
actions initiate account actions. Do not add hidden automation, bulk messaging,
mass-DM behavior, token sharing, challenge bypasses, or claims that the client
is affiliated with Discord or safe from account action.

## Start with the right source of truth

- Read [docs/README.md](docs/README.md) and the canonical document relevant to
  the task. Do not load every historical implementation detail into context.
- Inspect the current code, tests, configuration, and working-tree state before
  relying on a dated document or roadmap description.
- Preserve unrelated and dirty work. Make the smallest coherent change and
  distinguish direct evidence from inference.

## Decide the current checkout mode

Worktree rules are conditional. Do not assume they apply because this file
mentions worktrees or because `git worktree list` contains other checkouts.

When checkout identity matters for building, testing, cleanup, concurrent work,
or Computer Use, execute:

```sh
./script/worktree_runtime.sh
```

- `Checkout: main` means this is the ordinary canonical checkout. Work normally
  here with `dist/SakuraCord.app` and `dev.sakuracord.SakuraCord`. Do not create
  a worktree, set `SAKURACORD_WORKTREE_ID`, or apply linked-only setup/cleanup
  guidance unless the user actually requested concurrent writers.
- `Checkout: linked worktree` means isolated variant behavior is active. Follow
  [docs/PARALLEL_WORKTREES.md](docs/PARALLEL_WORKTREES.md).

`script/worktree_test.sh` only serializes tests in the current checkout. It does
not create, select, or switch to a worktree.

## Roadmap workflow

The deployed roadmap service is the only source of truth for planned work,
priority, lifecycle state, acceptance criteria, research, verification, and
linked Discord discussions. Use the
[@roadmap-management](plugin://roadmap-management@personal) plugin and its
roadmap tools. Do not create or maintain a repository `ROADMAP.md`.

For roadmap work:

1. Search or list items to resolve the stable item ID.
2. Read the complete current item and revision before any mutation.
3. Use that exact revision as `expectedRevision`; on conflict, read again and
   reapply only the intended change.
4. Do not infer progress from code presence or intuition. Cite acceptance
   criteria, tests, commits, pull requests, benchmarks, or an explicit manual
   assessment with rationale.
5. Record actual verification through the roadmap verification tool. A normal
   transition to done requires acceptance criteria, every criterion satisfied,
   and at least one passing verification result.
6. Use roadmap history for “what changed” questions. Use sync status before
   reconciliation when diagnosing Discord projection drift.

Community submissions remain in the review inbox until a maintainer accepts or
links them. Reactions and duplicate counts are signals, not automatic priority.
Roadmap data and per-item state never belong in Git commits. Repository
inspection is evidence to review, not proof that an item is complete.

## Linked-worktree isolation

This section applies only to an actual linked checkout or to a coordinating task
that is deliberately creating separate linked worktrees for concurrent writers.
A single writer in the main checkout should not enter the parallel-worktree
workflow.

- Give every concurrently writing agent its own Codex-created worktree. Never
  build or edit through another agent's checkout.
- Variant app identities are only for actual Codex linked worktrees. A normal
  checkout must build `dist/SakuraCord.app` with display name `SakuraCord` and
  bundle identifier `dev.sakuracord.SakuraCord`. Do not set
  `SAKURACORD_WORKTREE_ID` to manufacture a variant identity.
- Use repository environment actions or `script/build_and_run.sh`; they assign
  each worktree a unique app name, bundle, process scope, and build cache. Do
  not use `pkill`, `killall`, or a hard-coded `dist/SakuraCord.app` path in
  worktree automation.
- Use `--offline`, `--offline-long-server-list`, or
  `--offline-forum-performance` for agent visual testing. Linked-worktree
  live-account launches are blocked by default. Agents must not set the
  live-worktree override.
- Use `script/worktree_test.sh` to serialize tests within one checkout. Builds
  and tests in separate worktrees remain independent.
- Integrate results patch-by-patch. Never replace a shared file wholesale from
  another worktree. Resolve overlaps semantically, run `git diff --check`,
  search for conflict markers, and verify the combined result.

The full procedure is in
[docs/PARALLEL_WORKTREES.md](docs/PARALLEL_WORKTREES.md).

## Computer Use app targeting

- Never target SakuraCord by the generic display name. A read-only state lookup
  can launch an ambiguous installed, authenticated, offline, or worktree build.
- Execute, do not source, `script/worktree_runtime.sh` from the checkout being
  tested. First confirm whether it reports `Checkout: main` or
  `Checkout: linked worktree`, then use the complete bundle path from its `App:`
  line as the Computer Use target.
- Confirm the printed executable is the scoped running process. If it is not
  running, launch that exact bundle with the intended offline arguments.
- After every action, fetch fresh state from the same absolute bundle path.
  Never switch to a display-name target mid-session.

## Protocol research proportional to risk

UI-only work, local persistence, mock fixtures, tests, accessibility, styling,
and mechanical refactors do not require fresh Discord protocol research when
they leave the established network contract unchanged.

Every new or materially changed production REST request, Gateway path,
authentication exchange, upload, or other communication with Discord requires
a complete, current cross-reference of all of the following:

1. Discord's current public API, Gateway, status-code, and rate-limit
   documentation wherever those documents cover the behavior;
2. the corresponding implementation in the current official production web
   client bundle, including its route constants, action, state store, and
   Gateway reconciliation path;
3. the corresponding pinned Paicord path;
4. the corresponding pinned Swiftcord v1 path; and
5. the exact visible or sanitized protocol behavior of a current clean,
   unmodified official Discord client when static sources leave a material
   ambiguity.

Paicord and Swiftcord are mandatory cross-references even when the official web
bundle appears conclusive. Record explicitly when either reference has no
corresponding implementation; absence is evidence, not permission to skip it.
Treat the current official web bundle as the primary operational reference for
normal-user client behavior that public documentation does not cover. Treat
public documentation as the authority for supported API semantics, status
codes, and rate limits. The minified bundle is dated first-party implementation
evidence, not a promise of API stability.

Trace the complete feature path: UI trigger, cache/state lookup, Gateway
dependency, route or opcode, headers, request body, sequencing, request count,
response decoding, errors, rate limits, retries, cancellation, invalidation,
and reconciliation. Begin with the exact current first-party request and event
shape, then resolve every mismatch against Paicord and Swiftcord. Swiftcord v1
is a historical design reference and Paicord is a current compatibility
reference; neither outranks contradictory current first-party evidence.
Any SakuraCord difference must be deliberate, safer or architecturally
necessary, documented with evidence, and covered by request-contract and
request-budget tests.

Capture only sanitized protocol shape. Never store or share credentials,
authorization headers, cookies, message bodies, personal data, fingerprints,
installation identifiers, or unsanitized traffic. Never replay captured
credentials or synthesize server-issued values.

Record narrow, time-bound evidence in the roadmap item, pull request, or commit
description. Update [docs/PROTOCOL_BASELINE.md](docs/PROTOCOL_BASELINE.md) only
when a change establishes or supersedes a durable repository-wide contract. Do
not create a feature-specific Markdown implementation journal.

## REST and account safety

- Route every authenticated request through `DiscordRESTProvider`'s central
  transport, rate-limit coordinator, metadata source, logging, and safety
  circuit. Do not create a one-off authenticated `URLSession`.
- Preserve the current retry contract unless the protocol comparison and tests
  justify changing it: ordinary GETs have at most two attempts and retry only
  after a server `429`; mutations have one attempt. The application-command
  index has its separately tested three-request `202`/`429` readiness bound.
- Use server-provided bucket and cooldown data. Never hard-code a rate limit,
  retry early, spin, or add speculative “just in case” probes.
- Preserve nonces/idempotency and Gateway reconciliation. An ambiguous mutation
  result must not become an automatic second user action.
- Native login may follow its separately documented, bounded Paicord-style
  status retry and one user-completed CAPTCHA replay. Cancelling or failing a
  challenge never replays it. Never synthesize, borrow, or bypass a challenge.
- Validate channel type, permissions when known, required fields, limits, and
  attachment metadata before transmission.
- Coalesce identical reads, deduplicate in-flight work, paginate deliberately,
  cancel superseded work, and cap fan-out.
- Log only sanitized route templates, status/error codes, bucket identifiers,
  request counts, and timing. Never log credentials or message content.

### Direct-message guardrail

DM behavior needs extra review because a SakuraCord DM send has previously
triggered an account restriction.

- Treat opening/creating a DM, loading an existing DM, and sending as distinct
  actions. Do not create or reopen a DM on every send.
- Before materially changing DM creation or sending, recheck the current
  official web-client bundle, a clean official client, Paicord, Swiftcord v1,
  request ordering, body, nonce, context, challenge handling, and Gateway
  reconciliation.
- Serialize duplicate open/create attempts and deduplicate sends. Never invent
  a second send after an ambiguous timeout.
- Handle `40003`, `40004`, verification/challenge responses, and connection
  revocation at the same bounded scope as the reviewed reference path.
- Keep incomplete DM mutation behavior experimental and gated until contract
  and request-budget tests pass.

## Gateway requirements

- Keep an explicit testable state machine for connect, Hello, Identify/Resume,
  heartbeat, ACK, Ready, reconnect, invalid session, backoff, and shutdown.
- Track heartbeat ACKs, prefer Resume when valid, bound reconnect attempts, and
  prevent stale socket generations from affecting a newer connection.
- Understand and source Identify metadata correctly. Do not paste captured
  blobs or claim official-client identity.
- Add deterministic fixtures for each new opcode and transition.

## Testing and live-account rules

- Default to mocked transports, sanitized fixtures, deterministic clocks, and
  synthetic accounts/guilds. Offline coverage remains required for every behavior that can be represented faithfully without authenticated server state.
- Add request-contract tests for method, route, query, headers, body,
  status/error handling, rate-limit behavior, retries, and mutation nonce when
  any of those change.
- Add request-budget tests for fan-out, caching, pagination, cancellation, and
  deduplication.
- Use `./script/worktree_test.sh protocol`, `app`, or `all`. For packaged-app
  claims, run `./script/build_and_run.sh package` and strict deep `codesign`
  verification. A successful compile is not shipped-app or visual proof.
- Every agent must run `./script/install_git_hooks.sh` once in each fresh clone
  before its first commit or push and verify
  `git config --local --get core.hooksPath` reports `.githooks`. The installer
  refuses to replace a different existing hooks path; stop and report that
  conflict instead of bypassing it.
- Run `./script/code_quality.sh check` before reporting a change ready to push.
  The versioned pre-commit hook checks the staged index, and pre-push checks the
  committed ref tips and any staged Swift snapshot with that same pinned
  command; do not bypass either hook.

## Documentation rules

- Keep the root README accurate for public setup, safety, tests, and releases.
- Keep the docs set small and canonical; follow
  [docs/README.md](docs/README.md).
- Planning and progress belong in the roadmap service. Durable architecture,
  protocol, workflow, and legal facts belong in the existing canonical docs.
- Verify commands, paths, versions, capability gates, and release claims
  against current source before documenting them.
- Date observations and state what was not verified. Do not present a build,
  benchmark, live check, or memory-derived fact as current without evidence.

## Completion checklist

Before finishing, apply the parts relevant to the change:

- Did the implementation stay within the interactive-client scope?
- Did protocol-changing work compare the required references and record any
  deliberate difference?
- Are request counts, ordering, caching, cancellation, retries, and
  reconciliation explicit and tested?
- Are authentication, permission, restriction, malformed-response, and
  challenge paths bounded without bypasses?
- Do automated tests run offline without secrets or personal data?
- If an authenticated-only exception was necessary, was its inherently
  authenticated trigger identified, the exact API path re-audited, and fresh
  action-specific user permission obtained before the test?
- Were the actual relevant tests run, and were package, signature, live, and
  visual checks reported separately?
- Was durable documentation updated without creating duplicate roadmap or
  feature-journal state?
