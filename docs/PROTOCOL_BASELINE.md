# Discord protocol baseline

This is the entry point for changing SakuraCord's Discord communication.
It records application invariants, not a supported third-party Discord API.
Read the relevant topic before changing a route, payload, retry, cache or event
consumer. Source and contract tests establish what this checkout implements;
dated observations establish why a wire shape was chosen.

## Contract map

| Topic | Read for |
| --- | --- |
| [Session and authentication](protocol/SESSION.md) | Client metadata, login, Gateway lifecycle, event delivery, diagnostics. |
| [Messages and uploads](protocol/MESSAGING.md) | Sends, history, reactions, polls, threads, commands, media preparation. |
| [Read state and Inbox](protocol/READ_STATE.md) | Acknowledgements, Undo, mentions, events, notifications. |
| [Guilds and membership](protocol/GUILDS.md) | Invites, onboarding, channel customization, Guide, member discovery. |
| [Profiles and synchronized settings](protocol/SETTINGS.md) | Profile saves, nicknames, group-DM edits and leaving, widgets, status, protobuf updates, folders and favourites. |
| [Voice and streams](protocol/VOICE.md) | Calls, screen sharing, voice recovery, soundboard. |

Architecture owns [component and persistence boundaries](ARCHITECTURE.md).
Development owns [launch and verification procedures](DEVELOPMENT.md).

## Shared transport rules

- All authenticated HTTP goes through `DiscordRESTProvider`'s central transport.
  Feature views and helpers must not create another authenticated URLSession.
- REST and Gateway share provider-owned client metadata. Read configured identity
  values from [DiscordProductionBaseline.swift](../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordProductionBaseline.swift);
  do not copy a build number into another guide or fabricate installation IDs.
- Rate limits come from Discord's headers/body. Respect route, bucket and global
  cooldowns; do not probe early or hard-code an assumed requests-per-second rate.
- Keep retries bounded. A lost mutation response does not establish that the
  server rejected the action. Reconcile through returned state/Gateway rather
  than replaying an ambiguous mutation automatically.
- Permission/not-found errors remain operation-scoped when they do not indicate
  an account/session failure. Authentication, restrictions, unsupported challenges
  and malformed mutation responses retain the shared safety boundary.
- Preserve typed snowflakes and unknown protobuf fields. Presentation order,
  cache presence and missing optional fields are not substitutes for permission
  checks or authoritative state.

### Attempt budgets

These are operation-specific bounds, not permission to retry every failure.
See [REST transport](../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordRESTTransport.swift)
and each topic's contract tests before changing them.

| Operation | Bound and trigger |
| --- | --- |
| Ordinary authenticated read, including read-only DM-search POST | At most two created requests: retry after server `429` cooldown or once on a replacement pool after a confirmed REST stall. |
| Ordinary authenticated mutation | One attempt; no automatic replay after `429`, timeout or ambiguous result. |
| Message creation (ordinary, sticker and poll sends) | Original plus at most four replays after a non-slowmode `429` cooldown, retaining the nonce. Slowmode `429`, timeouts and ambiguous results are not replayed. See [sends](protocol/MESSAGING.md#sends-and-history). |
| User-initiated status/custom-status save | One additional `429` attempt when the server delay is at most 30 seconds. Automatic pending-status saves do not retry. See [status](protocol/SETTINGS.md#status-and-custom-status). |
| Command-index readiness | At most three created GETs for the tested `202`/`429` flow. |
| Message-search indexing | Original plus at most five `202` retries, using the server delay or a five-second fallback when absent. Each logical read retains the ordinary read budget. |
| Cold installation/fingerprint preflight | Original plus at most three bounded status retries for `429`, `500`, `502`, `504`. |
| Stored/QR credential installation repair | Once per provider: one unauthenticated Apex GET, then one experiments GET only if needed; no automatic retry or login replay. |
| Password/MFA | Original plus at most two bounded retries for the documented transient status set above. |
| Report-service OAuth2 authorization | One ordinary read of the consent details, then one authorizing POST that is never replayed. See [report-service sign-in](protocol/SESSION.md#report-service-sign-in). |
| Remote-auth ticket exchange | Original plus at most three bounded transient-status retries. |
| User-completed login or server-join CAPTCHA | At most one challenged-request replay after human completion; a second challenge terminates the attempt. |

A later explicit user action is distinct from automatic retry. Message retry
retains its nonce; operation-specific exceptions must be documented beside their
contract and linked from this table.

## Capability gates

[DiscordRESTProvider.supports](../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordRESTNotificationsAndMessaging.swift)
is authoritative for the [provider capability interface](../Packages/DiscordProtocol/Sources/DiscordProtocol/ChatProvider.swift).
It currently enables forums, slash commands, message components, returned-modal
submission, remote component choices, GIFs, forwarding, soundboard, sticker
browsing and sticker sending. Other features also have permission, membership or
entitlement checks outside this capability enum.

Rendering a payload does not authorize its corresponding mutation. UI controls
must ask the provider and check current account/channel eligibility.

## Evidence required for a protocol change

Cross-check public Discord documentation where applicable, the current official
production web bundle, pinned Paicord, and pinned Swiftcord v1. Use a clean
first-party client observation when static sources leave material ambiguity.
Public documentation governs supported semantics; first-party request construction
is the operational reference for undocumented user-client behaviour. Other clients
are corroboration, not permission to copy an obsolete path.

Record the observation date and reference build/revision; route, headers, body,
sequence and request count; response/error behaviour; retries, cache effects and
Gateway reconciliation. State when a reference has no equivalent implementation.
Explain deliberate SakuraCord deviations and protect important contracts with
meaningful mocked transport/request-budget coverage.

Keep the current rule and necessary public source references in its topic document.
Keep working research notes and capture-session details out of the repository.
Do not append a chronological implementation journal to this baseline or maintain
a second supposedly complete route/opcode list. The topic source links lead to
the maintained route builders and dispatch handlers.

## Verification boundary

Use sanitized fixtures, injected clocks and mocked transports for deterministic
protocol verification with Discord networking disabled. Follow [Testing](TESTING.md)
when deciding whether a change warrants committed tests.

A read-only authenticated pass can complement those checks when a configured
session exists. Agent-run verification must not deliberately mutate remote
accounts or content without the user's explicit authorization for the specific
bounded action. Connection maintenance and reading existing state are allowed;
sending, settings writes, read acknowledgements, joins, calls and login/challenge
actions require attention to their actual account effects. Use the scoped launch
controls in Development where applicable. If no configured session exists,
report the missing live verification; do not extract a credential to create one.
