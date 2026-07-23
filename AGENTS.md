# SakuraCord agent guidance

This file applies to the entire repository.

## Parallel Codex worktree isolation

- Give every concurrently writing agent its own Codex-created worktree. Never
  build or edit through another agent's checkout.
- Isolated app identity is only for an actual Codex worktree checkout. A normal
  checkout, including the primary checkout used by an ordinary Codex task, must
  always build and launch the canonical `dist/SakuraCord.app` with display name
  `SakuraCord` and bundle identifier `dev.sakuracord.SakuraCord`. Do not set
  `SAKURACORD_WORKTREE_ID` or otherwise manufacture a variant identity outside
  an actual Codex worktree.
- Use the repository environment actions or `script/build_and_run.sh`; they
  assign a unique app name, bundle identifier, bundle path, and process scope to
  each linked worktree. Do not use `pkill`, `killall`, or a hard-coded
  `dist/SakuraCord.app` path in worktree automation.
- Use `--offline` or `--offline-long-server-list` for agent visual testing.
  Codex-worktree live-account launches are intentionally blocked by default.
- Run tests through `script/worktree_test.sh` when another operation may be
  active in the same checkout. Builds and tests in separate worktrees remain
  independent.
- Integrate parallel results patch-by-patch into the current target worktree.
  Never replace a shared file wholesale with a source worktree's copy. Resolve
  overlaps semantically, run `git diff --check`, search for conflict markers,
  and verify the combined result. The full procedure is in
  `docs/PARALLEL_WORKTREES.md`.

## Computer Use app targeting

- Never target SakuraCord in Computer Use by the generic display name
  `SakuraCord`. A read-only state request can launch an app when the target is
  not already running, and the display name is ambiguous across installed,
  authenticated, offline, and worktree builds.
- Before any Computer Use inspection or action, execute (do not source)
  `script/worktree_runtime.sh` from the checkout being tested and use the exact
  app bundle path printed on its `App:` line as the Computer Use `app` target.
  The full bundle path is preferred over the bundle identifier because separate
  copies can share the canonical main-checkout identifier.
- Confirm that the printed executable is the scoped running process before
  interacting. If it is not running, launch that exact bundle explicitly with
  the intended offline arguments first; do not let a generic Computer Use
  lookup choose or launch another copy.
- After every Computer Use action, fetch fresh state from that same exact app
  path. Never switch to a display-name target mid-session.

SakuraCord is an interactive, native macOS Discord client written in Swift and SwiftUI. It is not intended to be a self-bot, spam tool, or unattended account-automation system: user-visible actions in the app initiate account actions. Its purpose is to provide a fast, resource-efficient, Liquid Glass client experience without Discord's Electron runtime.

SakuraCord is nevertheless unofficial and uses a normal Discord account session through protocol surfaces that Discord does not document or support as a third-party-client API. Treat protocol accuracy and Paicord parity as important account-safety considerations. Paicord is the default compatibility reference for behavior it implements, especially request construction, challenge handling, and bounded retries. Deliberate differences are acceptable when current official-client evidence, public documentation, or SakuraCord's architecture supports a better fit; record the reason when the difference changes network behavior. No degree of parity can guarantee that Discord will accept the client or refrain from account action.

## Protocol research proportional to the change

Use research effort proportional to the risk and novelty of the change. New or changed production network behavior—including REST routes, Gateway or voice/video signaling, authentication, messages, DMs, reactions, emoji, attachments, presence, profiles, member lists, or remote settings—requires comparison with the relevant references below:

1. The corresponding behavior in Paicord.
2. The corresponding behavior in Swiftcord v1.
3. The exact behavior of a current, clean, unmodified official Discord client.

Also consult Discord's current public API documentation, status/error-code documentation, and rate-limit documentation wherever applicable. Public documentation is authoritative for the behavior it covers, but it does not cover every normal-client route or payload.

UI-only work, local persistence, mock fixtures, tests, accessibility, styling, and mechanical refactors do not require fresh protocol research when they leave the established network contract unchanged. Existing recent repository baselines may be reused for small changes to an already documented call flow. For new, high-risk, or materially changed production calls, complete the comparison before implementation. If one reference is unavailable or does not implement the feature, note that briefly and use the remaining evidence rather than blocking the work.

## Paicord and Swiftcord v1 review

- For protocol-changing work, trace the complete feature path rather than only the endpoint string: UI trigger, state/cache lookup, Gateway dependency, request construction, headers, body, response decoding, error handling, retries, and invalidation.
- Swiftcord v1 is currently non-functional and old. Its code is still a useful design and protocol reference, but details reused from it should be checked against newer evidence.
- Paicord is SakuraCord's primary operational reference. Prefer its established behavior when the current official client and SakuraCord architecture do not provide a reason to differ, and document meaningful protocol differences without treating parity as a goal by itself.
- Swiftcord v1 remains a historical design reference rather than the operational baseline.

## Official-client protocol examination

For high-risk, undocumented, or uncertain behavior, use a clean, unmodified official Discord web or desktop client and an account/session the user is authorized to inspect. For a small change to an established flow, current public documentation, public client assets, and a recent repository baseline may be sufficient. When fresh examination is warranted, compare the network and Gateway behavior needed for the feature:

- HTTP method, API version, route, path parameters, query parameters, and content type.
- Request body shape, field presence versus omission, nullability, types, nonce/idempotency fields, attachment metadata, reply/message references, and context fields.
- Header names, values, and provenance: distinguish stable client metadata, values derived from the real local environment, values issued by Discord, and per-session/per-request values.
- Number of calls caused by one UI action, call ordering, concurrency, debouncing, cancellation, batching, pagination, lazy loading, prefetching, and cache reuse.
- Gateway opcode and payload shape, capabilities, client state, subscriptions, sequence handling, heartbeat/ACK behavior, resume, reconnect, and invalid-session behavior.
- Success status, error status and Discord error code, response headers, rate-limit bucket/scope, response-body shape, and cache invalidation caused by the operation.

Capture only what is needed to understand protocol semantics. Never commit or share account tokens, authorization headers, cookies, message bodies, personal data, server-issued fingerprints/installation identifiers, or unsanitized captures. Do not replay captured credentials. Values issued by Discord must come from the legitimate flow that issues them; never hard-code or borrow them from another account/session.

Protocol parity is for compatibility, correctness, predictable performance, and avoiding malformed or anomalous request behavior. Paicord-style interactive challenge completion is allowed; bypassing a challenge is not. Do not add hidden unattended actions, spam behavior, or unbounded retry loops.

## Protocol implementation record

Changes that add or materially alter production routes, payloads, headers, Gateway behavior, retries, authentication, or account actions should include a proportionate implementation note in the PR/commit description or associated repository documentation. UI-only and local-only changes do not need one. A short note is enough for a narrow change to an established flow; significant or high-risk work should cover the applicable items below:

- Official Discord documentation consulted.
- Paicord repository revision and relevant findings.
- Swiftcord v1 repository revision and relevant findings.
- Official-client version/build, observation date, and a sanitized call-flow description.
- For substantial changes, a comparison table listing route/payload/header/sequencing differences between the available references and SakuraCord.
- The chosen behavior and why it matches the current official client or deliberately differs.
- Expected request count for cold cache, warm cache, repeated UI action, and failure/retry cases.
- Rate-limit, account-restriction, rollback, and testing considerations.

Update `docs/PROTOCOL_BASELINE.md` when a change establishes or supersedes a repository-wide protocol baseline. Date observations clearly and avoid presenting an older observation as current.

## REST request safety and parity

- Route authenticated requests through the shared transport and rate-limit coordinator. Do not create one-off authenticated `URLSession` paths that bypass common scheduling, logging, or shutdown behavior.
- Use Paicord's endpoint, payload, header, sequencing, challenge, and retry semantics as the default for the same user action, while allowing documented differences based on newer official behavior or SakuraCord's architecture. Avoid extra “just in case” requests or speculative probes.
- Do not hard-code rate limits. Track the server's `X-RateLimit-Bucket`, major parameters, scope, remaining count, reset time, and `Retry-After`/`retry_after` values.
- A fixed global delay can be a temporary safety ceiling, but it is not a replacement for Discord's bucket model. Scheduling must prevent bursts without making the client unnecessarily slow.
- Prefer Paicord's current default retry policy unless route-specific evidence supports another bounded policy: retry `429`, `500`, `502`, and `504` at most three times; use its header-based backoff ceiling and fallback exponential backoff; never retry early or spin. Record the pinned revision and any meaningful deviation for protocol-changing work.
- After the user successfully completes a CAPTCHA or MFA challenge, replay the challenged request with the Paicord-equivalent challenge headers and retry counter. Paicord's standard bounded status-code retries may still apply after that replay. Cancelling or failing a challenge does not replay the request. Never synthesize, borrow, or bypass a challenge solution.
- Handle `401`, `403`, repeated `404`, malformed responses, verification requirements, and restriction codes the way the pinned Paicord revision handles the equivalent route. Always bound retries and surface the result; open the session-wide circuit only where Paicord does so or where continuing would cross the scope boundary.
- Mutations may use Paicord's bounded status-code retry behavior. Preserve Paicord's nonce/idempotency fields and Gateway/REST reconciliation so a retry does not become an extra user action.
- Coalesce identical reads, deduplicate in-flight loads, cache stable data, paginate deliberately, cancel superseded work, and cap concurrency.
- Validate payloads before transmission: channel type, permissions when known, required fields, size/count limits, and attachment metadata.
- Log sanitized route templates, methods, status/error codes, request counts, bucket identifiers, and timing. Never log credentials or message content.

## Gateway requirements

- Maintain an explicit, testable state machine for connect, hello, identify/resume, heartbeat, ACK tracking, ready, reconnect, invalid session, backoff, and shutdown.
- Match current official-client identify, capabilities, client-state, compression/encoding, and subscription semantics only after comparing them with Paicord and Swiftcord v1.
- Metadata in identify/request properties must be understood and sourced correctly. Do not blindly paste a captured blob or claim values that belong to a different account/session/device.
- Track heartbeat ACKs; do not merely send periodic heartbeats. A missing ACK must close/reconnect according to observed protocol behavior.
- Prefer resume over a fresh identify when the session is resumable. Bound reconnect attempts and never reconnect in a tight loop.
- Add deterministic fixtures for every opcode and transition used by a new feature.

## Direct-message guardrail

DM behavior requires extra review because a SakuraCord DM send has already triggered an account disablement.

- Distinguish opening/creating a DM channel, loading an existing DM, and sending into it. Do not create/open a DM as part of every send.
- Before materially changing or broadly enabling DM creation/sending, compare an equivalent current official-client action and inspect the relevant Paicord and Swiftcord v1 paths. Pure UI, cache, or fixture work can reuse the existing DM baseline.
- Match the official request body, nonce, context fields, call ordering, and Gateway reconciliation. Small omissions can change how Discord classifies the operation.
- Serialize duplicate open/create attempts and deduplicate sends. Apply only the bounded retry and challenge behavior present in the pinned Paicord path; never invent a second send after an ambiguous timeout.
- Handle Discord error `40003` (opening DMs too quickly), `40004` (sending temporarily disabled), verification/challenge responses, and connection revocation with the same request/session scope and user-visible behavior as the pinned Paicord path.
- Keep incomplete DM creation/sending behavior visibly experimental and disabled by default until fixture tests and the implementation record are complete.

## Testing and live-account rules

- Default to mocked transports, sanitized fixtures, deterministic clocks, and synthetic accounts/guilds. All core behavior must be testable with Discord networking disabled.
- Add or update request-contract tests when a change affects method, route, query, headers, body, status/error handling, rate-limit scheduling, retry count, or mutation nonce behavior.
- Add request-budget tests for any feature that can fan out. Fail tests when a UI action unexpectedly produces extra requests.
- Do not make real Discord calls merely because a build or unit test runs. Live tests require an explicit manual action and a stated expected call sequence.
- Keep live tests narrow: one feature, one manual action, and one inspected result at a time. Do not use an account whose loss would be unacceptable.
- In a live test, allow Paicord-equivalent interactive CAPTCHA/MFA completion and its bounded status-code retries. Never solve a challenge without the user, retry beyond Paicord's policy, or continue an unattended test loop.
- When Paicord stops, preserve sanitized diagnostics and stop SakuraCord at the same scope. Investigate unexpected results with the relevant references before another live test.

## Scope boundary

- Do not add self-bot features, unattended account actions, bulk messaging, spam, scraping, mass-DM behavior, or token sharing. These are outside SakuraCord's purpose.
- Do not bypass CAPTCHAs, verification challenges, rate limits, permission checks, account restrictions, or other safety controls. Presenting a Paicord-equivalent challenge for the user to complete and replaying it with Discord-issued solution data under Paicord's bounded retry counter is permitted.
- Do not claim affiliation with Discord or claim that SakuraCord is ban-safe.
- Do not weaken Keychain storage, secret redaction, the offline network switch, or the REST safety circuit for convenience.

## Completion checklist

For production protocol changes, use the applicable parts of this checklist; UI-only and local-only work can skip protocol-specific items:

- Were the relevant Paicord, Swiftcord v1, official-client, and public-documentation references reviewed or covered by a recent baseline?
- Are reference revisions/builds and sanitized findings recorded when the change warrants an implementation note?
- Does the call flow match the official client's current semantics, or is every deliberate difference justified?
- Are request count, ordering, concurrency, caching, pagination, cancellation, and deduplication explicit?
- Are Discord's bucket headers and server-provided retry intervals handled centrally?
- Do mutation retries match Paicord's bounded policy and preserve its nonce/idempotency behavior?
- Do authentication, permission, malformed-response, challenge, and restriction paths match the pinned Paicord behavior without bypasses or unbounded retries?
- Are tests runnable without a live Discord account and free of secrets/personal data?
- Are DM and high-fan-out features gated until their contract tests and request budgets pass?
- Does SakuraCord stop, retry, or replay at the same scope and bound as the pinned Paicord path?
