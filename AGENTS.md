# SakuraCord agent guidance

This file applies to the entire repository. SakuraCord is an interactive native
macOS Discord client in which user-visible actions initiate account actions.

## Sources of truth

- Read [docs/README.md](docs/README.md), then only the canonical document
  relevant to the task.
- Inspect current code, tests, configuration, and Git state before relying on
  roadmap or documentation claims.
- Prefer the smallest coherent change and distinguish evidence from inference.

## Task-specific workflows

- Roadmap state lives only in the deployed roadmap service. For roadmap work,
  use the [@roadmap-management](plugin://roadmap-management@personal) plugin;
  do not create a repository `ROADMAP.md` or commit roadmap state.
- For Computer Use, run `./script/runtime.sh` and target the complete bundle
  path from its `App:` line. Do not target SakuraCord by display name or switch
  targets during a session.
- For release notes or a Discord announcement, read
  [docs/RELEASE_NOTES_STYLE.md](docs/RELEASE_NOTES_STYLE.md) and
  [docs/DISCORD_RELEASE_ANNOUNCEMENTS_STYLE.md](docs/DISCORD_RELEASE_ANNOUNCEMENTS_STYLE.md).
  Resolve and inspect the exact requested tag before drafting. Show both drafts
  before writing `Releases/vX.Y.Z.json` unless asked to save immediately.

## Discord protocol changes

UI-only work, local persistence, mock fixtures, tests, accessibility, styling,
and mechanical refactors do not require fresh Discord protocol research when
they leave the network contract unchanged.

Before adding or materially changing a production REST request, Gateway path,
authentication exchange, upload, or other Discord communication, compare:

1. current public Discord API, Gateway, status-code, and rate-limit docs;
2. the corresponding current official production web-client route, action,
   state store, and Gateway reconciliation path;
3. the corresponding pinned Paicord path;
4. the corresponding pinned Swiftcord v1 path; and
5. sanitized behavior from a clean official client when static sources leave a
   material ambiguity.

Record when a reference has no corresponding implementation. Public docs are
authoritative for supported semantics, status codes, and rate limits; the
official web client is current operational evidence where public docs are
silent. Paicord and Swiftcord are mandatory cross-references, not higher
authorities than contradictory current first-party evidence.

Trace the UI trigger, cache and Gateway dependencies, route or opcode, headers,
body, sequencing, request count, decoding, errors, rate limits, retries,
cancellation, invalidation, and reconciliation. Cover deliberate SakuraCord
differences with request-contract and request-budget tests.

Capture only sanitized protocol shape. Never retain credentials, authorization
headers, cookies, message bodies, personal data, fingerprints, installation
identifiers, or unsanitized traffic. Do not replay captured credentials or
synthesize server-issued values.

Put narrow, dated evidence in the roadmap item, pull request, or commit
description. Update [docs/PROTOCOL_BASELINE.md](docs/PROTOCOL_BASELINE.md) only
for a durable repository-wide contract; do not create feature journals.

## Production network invariants

- Route authenticated requests through `DiscordRESTProvider`'s transport,
  rate-limit coordinator, metadata source, logging, and safety circuit.
- Ordinary GETs have at most two attempts and retry only after a server `429`;
  mutations have one attempt. The application-command index has its separately
  tested three-request `202`/`429` readiness bound. Change these limits only
  with protocol evidence and tests.
- Use server bucket and cooldown data. Do not hard-code rate limits, retry
  early, spin, or add speculative probes.
- Preserve mutation nonces, idempotency, and Gateway reconciliation. Never turn
  an ambiguous result into a second account action.
- Native login permits only its documented bounded status retry and one replay
  after a user-completed CAPTCHA. Cancellation or failure does not replay it.
- Validate known permissions, channel type, required fields, limits, and
  attachment metadata before transmission.
- Coalesce identical reads, deduplicate in-flight work, paginate deliberately,
  cancel superseded work, and cap fan-out.
- Logs may contain sanitized route templates, status/error codes, bucket
  identifiers, request counts, and timing—not credentials or message content.

### Direct-message mutations

A SakuraCord DM send has previously triggered an account restriction. Before
changing DM creation or sending, recheck the official web client, a clean
official client, Paicord, Swiftcord v1, request ordering, body, nonce, context,
challenge handling, and Gateway reconciliation.

- Opening or creating a DM, loading it, and sending are distinct actions.
- Serialize duplicate open/create attempts and deduplicate sends.
- Never retry a send after an ambiguous timeout.
- Bound `40003`, `40004`, verification/challenge, and connection-revocation
  handling to the reviewed reference behavior.
- Keep incomplete DM mutation behavior gated until contract and request-budget
  tests pass.

## Gateway requirements

- Keep an explicit, testable state machine for connect, Hello, Identify/Resume,
  heartbeat, ACK, Ready, reconnect, invalid session, backoff, and shutdown.
- Track heartbeat ACKs, prefer Resume when valid, bound reconnect attempts, and
  prevent stale socket generations from affecting a newer connection.
- Source Identify metadata; do not paste captured blobs or claim official-client
  identity.
- Add deterministic fixtures for every new opcode and transition.

## Validation

- Default to mocked transports, sanitized fixtures, deterministic clocks, and
  synthetic accounts and guilds. Offline coverage is required whenever it can
  faithfully represent the behavior.
- When a network contract changes, test method, route, query, headers, body,
  status/error handling, rate limits, retries, mutation nonce, fan-out, caching,
  pagination, cancellation, and deduplication as applicable.
- Use `./script/test.sh protocol`, `app`, or `all`. A packaged-app claim also
  requires `./script/build_and_run.sh package` and strict deep `codesign`
  verification; compile, package, signature, live, and visual claims are
  separate.
- Before the first commit or push in a clone, run
  `./script/install_git_hooks.sh` and verify `core.hooksPath` is `.githooks`.
  Stop if the installer reports an existing conflicting hook path.
- Run `./script/code_quality.sh check` before reporting changes ready to push.

## Documentation

- Keep the root README accurate for public setup, safety, tests, and releases.
- Follow [docs/README.md](docs/README.md); update an existing canonical document
  instead of duplicating durable architecture, protocol, workflow, or legal
  information.
- Verify commands, paths, versions, gates, and release claims against current
  source. Date observations and state what was not verified.
