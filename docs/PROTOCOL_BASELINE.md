# Discord production protocol baseline

Last repository audit: 25 July 2026 at SakuraCord commit `32a6b8e`.

This document describes SakuraCord's durable network contract and the dated
evidence behind it. It is not a claim that Discord's undocumented
normal-account protocol is stable, supported, or safe from account action.

Detailed feature-by-feature journals that existed before the documentation
consolidation remain available in Git history through commit `32a6b8e`. New
narrow implementation evidence belongs in the canonical roadmap item, pull
request, or commit description rather than a new Markdown file.

## Evidence snapshot

The most recent repository-wide comparison was performed on 22–23 July 2026
using:

- Discord's public production web build `580156`, version hash
  `af6069991f1b0f884f278271a1fe36a2432d056c`, API version 9;
- a signed and notarized stable desktop host `0.0.401`; authenticated
  observations from a renderer with Equicord injection were limited to visible
  behavior or separately sanitized request semantics;
- Paicord revision `694761c1938b73bb60bd58942674dfe73aab1135`;
- Swiftcord v1 revision `14465d927ebe1ba34b3befa00f9365fad7b56eb9`
  and DiscordKit revision `2d42c69cafe592300a1a9d3a307bf485294026c7`;
  and
- Discord's public [Gateway](https://docs.discord.com/developers/events/gateway),
  [channel](https://docs.discord.com/developers/resources/channel),
  [message](https://docs.discord.com/developers/resources/message),
  [application-command](https://docs.discord.com/developers/interactions/application-commands),
  [permission and status-code](https://docs.discord.com/developers/topics/opcodes-and-status-codes),
  and [rate-limit](https://docs.discord.com/developers/topics/rate-limits)
  documentation where applicable.

No token, cookie, authorization header, message body, personal payload,
fingerprint, installation identifier, or unsanitized traffic is stored in this
repository. Treat every build number and observed payload as a dated snapshot,
not current official behavior.

## Current production capability gates

`DiscordRESTProvider.supports(_:)` is the authority:

| Capability | Production provider | Offline provider |
| --- | --- | --- |
| Forum channels | Enabled | Enabled |
| Slash commands | Enabled | Enabled |
| Message components and returned modals | Disabled | Enabled with fixtures |
| Remote component choices | Disabled | Disabled |
| GIF search | Disabled | Enabled with fixtures |
| Guild sticker catalog and sticker sending | Disabled | Enabled with fixtures |

Rendering decoded embeds, Components V2, stickers, attachments, and interaction
responses does not imply that the corresponding production mutation is enabled.
UI controls must consult the provider capability instead of inferring support
from a payload.

## Shared REST contract

Every authenticated request goes through `DiscordRESTProvider.perform`:

- API v9 under `https://discord.com/api/v9`;
- one `DiscordClientMetadata` source for session validation, REST, and Gateway
  Identify;
- authorization and client metadata applied centrally;
- conservative request-slot scheduling and server rate-limit state;
- sanitized route/status/bucket logging; and
- one provider-wide safety circuit shared with the Gateway session.

The default attempt budget is exact:

| Operation | Maximum attempts |
| --- | ---: |
| Ordinary authenticated GET | 2; the second attempt occurs only after a server `429` cooldown. |
| Authenticated mutation | 1; no automatic replay after `429`, timeout, or ambiguous failure. |
| Application-command index readiness | 3 created GETs for the separately tested `202`/`429` flow. |
| Native authentication status retry | Original plus at most 3 Paicord-policy retries for `429`, `500`, `502`, or `504`, subject to its delay ceiling. |
| User-completed login CAPTCHA | At most 1 replay of the challenged request. |

Any `429` pauses authenticated traffic until the server-provided cooldown.
Route and global bucket data come from response headers/body; SakuraCord does
not hard-code Discord rate limits or probe early.

Mutations preserve their nonce or idempotency fields and rely on REST/Gateway
reconciliation. A definite failed message may expose one explicit user retry
with the original nonce and `enforce_nonce`; an ambiguous timeout remains
waiting for confirmation and cannot be retried automatically.

Authentication failures, account restrictions, verification/challenge
responses, invalid client metadata, malformed mutation responses, and repeated
unexpected not-found responses can open the session-wide safety circuit.
Ordinary resource-scoped permission failures remain scoped when the decoded
Discord error does not indicate an account/session condition.

## Gateway contract

`GatewaySession` is the sole socket owner. The current baseline uses API v9
JSON with `zlib-stream`, not the official desktop ETF/`zstd-stream` path.

The state machine covers:

```text
disconnected -> connecting -> awaitingHello -> identifying -> ready
                                             -> resuming   -> ready
connecting/awaitingHello/identifying/resuming/ready -> backingOff -> connecting
any state -> stopped
```

Durable requirements:

- one Identify or Resume after each new Hello;
- a randomized first heartbeat and documented opcode-1 heartbeats;
- ACK tracking and reconnect after a missed ACK;
- persisted session ID, resume URL, and sequence;
- Resume before a fresh Identify when state is valid;
- explicit invalid-session and close-code handling;
- bounded, jittered reconnect backoff;
- a connection generation that prevents stale tasks from affecting a new
  socket; and
- explicit stop/logout with no reconnect.

SakuraCord deliberately does not copy the official client's undocumented QoS
heartbeat envelope or native-codec identity. Metadata must be understood and
sourced from the real local/session environment.

## Authentication

Native authentication is implemented without an embedded Discord login page:

- a cold password login performs experiments/fingerprint, login, then
  current-user validation;
- a warm password login performs login and validation;
- MFA adds one explicit verification request;
- hCaptcha is completed by the user and permits one challenged-request replay;
- QR login uses one remote-auth v2 WebSocket, an ephemeral RSA key, one ticket
  exchange, and one current-user validation after approval; and
- only a validated session credential enters `KeychainCredentialStore`.

Passwords, challenge solutions, fingerprints, and credentials are never
written to preferences, fixtures, GRDB, or logs. A cancelled or rejected
challenge does not create another request.

## Established feature contracts

These summaries preserve the durable network behavior from the consolidated
implementation records.

### Messages, typing, mentions, and links

- One user send creates one message POST with a Discord-epoch nonce,
  `chat_input` context, and `mobile_network_type: "unknown"`.
- Local typing waits 1.5 seconds, then sends at most one empty typing POST per
  eight-second activity window. Draft restoration, send, empty draft, channel
  change, and unsupported channel types cancel pending typing.
- Remote typing is keyed by channel and user, expires independently after ten
  seconds, ignores the current user, and clears when that author sends.
- Nonempty member autocomplete uses Gateway opcode 8 after a 200 ms debounce,
  with a ten-result limit and one-minute equivalent-query cache. Channel
  autocomplete is local.
- A loaded message link navigates locally. An absent target uses one existing
  bounded channel-history GET; it does not probe multiple pages or routes.

### Rich messages, reactions, and emoji

- History and Gateway message events share one loss-tolerant decoder. Updates
  merge only fields present in the event.
- Rich rendering issues no authenticated request by itself. Link previews use
  decoded embeds; SakuraCord does not scrape or preflight message URLs.
- Reactor previews use the documented reaction-user GET with `type=0&limit=5`.
  Loads are visible-row driven, coalesced, cached, limited to four concurrent
  reads, and never paginate.
- Guild emoji primarily comes from Ready/Guild Gateway payloads and
  `GUILD_EMOJIS_UPDATE`. A coalesced sequential guild-emoji GET is only a cache
  fallback; autocomplete itself performs no request.
- Nitro eligibility comes from `premium_type`; disallowed custom emoji
  composition falls back locally without an entitlement probe.

### Forums and threads

- The production forum browser is enabled and uses the dated official-client
  `threads/search` catalogue contract, with `post-data` preview batches of at
  most ten.
- Catalogue publication does not wait for starter previews. Pagination advances
  by server records, search is debounced and cancellation-aware, and malformed
  siblings do not discard valid posts.
- Creating a text-only post is one thread mutation. Attachments add one
  reservation plus one storage PUT per file before the final mutation.
- Tag, archive, lock, pin, and delete actions are explicit, permission-gated,
  centrally scheduled mutations with no automatic retry.
- Opening a known thread/post is local; an unknown thread URL uses one Get
  Channel read before the ordinary thread-history load.

### Slash commands

- A cold picker loads one context index and one user index, coalesced per
  target. Warm valid indexes add no request.
- Search, option editing, validation, and cached entity resolution are local.
- Remote autocomplete sends one type-4 interaction per settled distinct query,
  keyed by nonce, with no automatic retry.
- Execution sends one type-2 interaction. Attachments are reserved and uploaded
  first; the final interaction still has one attempt.
- The outer `guild_id` describes invocation context. Inner `data.guild_id` is
  present only for a guild-scoped command record.
- Gateway interaction events and response messages reconcile the pending nonce;
  rendering does not automatically fetch interaction detail.

### Server folders and voice-channel text

- Server folders decode from Ready `user_settings_proto` and subsequent
  settings updates. Folder rendering, ordering, and expansion add no REST
  request.
- Selecting voice-channel text chat uses the ordinary one-page message-history
  read and does not join voice. Reopening an already open pane adds no request.

### Guild metadata and member lookup

- Community rules-channel presentation uses the guild's authoritative
  `rules_channel_id`, not a channel name or UI heuristic, and adds no request.
- Hidden-channel metadata and effective access are derived from cached guild,
  role, member, and permission-overwrite data. Displaying the last-message
  snowflake time or allowed overwrite identities does not load hidden content.
- Opening a role reads one member-ID list, resolves missing users through
  Gateway member requests in batches of at most 100, and displays at most 1,000
  members. Cached members remove the corresponding Gateway batches.
- Ready read state admits only `read_state_type == 0` channel entries. If the
  payload repeats a channel entry, the newest payload-order entry wins instead
  of crashing dictionary construction.

## Direct-message safety boundary

Opening or creating a DM, loading history, and sending are separate operations.
Do not create/open a channel as part of every send. Duplicate creation and
sending must be serialized and deduplicated, and an ambiguous send must never
be repeated automatically.

Before materially changing DM creation or sending, recheck the current official
client, Paicord, Swiftcord v1, request body, nonce, context, ordering, challenge
behavior, and Gateway reconciliation. Keep incomplete paths capability-gated
until request-contract and request-budget tests pass.

## Verification and update rule

Every protocol contract that can be represented faithfully must be covered by
mocked transports, sanitized fixtures, deterministic clocks, request-contract
tests, and request-budget tests with Discord networking disabled.

An authenticated check is a narrow exception only when the defect genuinely
depends on authenticated or server-issued state that cannot be established in a
fixture. Such an issue does not require a performative offline reproduction or
offline attempt. Before an authenticated check is run, the exact API path must
be re-audited, mocked contract coverage must be added when it can meaningfully
exercise that path, and the user must grant fresh permission for the specific
action and bounded request sequence described in `AGENTS.md`. Agent-run
authenticated checks use the canonical main checkout, never a linked-worktree
live override.

When a production network contract changes:

1. compare the current official client, Paicord, Swiftcord v1, and public
   Discord documentation proportionally to risk;
2. record route, headers, body, sequencing, request count, response/error
   behavior, rate limits, retries, cache effects, and reconciliation;
3. state reference revisions/builds and observation dates;
4. record narrow evidence on the roadmap item, pull request, or commit; and
5. update this file only when the new evidence changes a durable
   repository-wide baseline.
