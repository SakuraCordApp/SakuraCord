# Discord production protocol baseline

Last repository audit: 4 August 2026, in a working tree based on SakuraCord
commit `5a2f42d`.

This document describes SakuraCord's durable network contract and the dated
evidence behind it. It is not a claim that Discord's undocumented
normal-account protocol is stable, supported, or safe from account action.

Detailed feature-by-feature journals that existed before the documentation
consolidation remain available in Git history through commit `32a6b8e`. New
narrow implementation evidence belongs in the canonical roadmap item, pull
request, or commit description rather than a new Markdown file.

## Evidence snapshot

The most recent repository-wide comparison was performed on 3 August 2026
using:

- Discord's public production web build `587597`, version hash
  `1a0e2d017c39d427ced2a95c829fd32621bddb14`, API version 9, and main asset
  `web.a8c0f0f55a5a68c4.js` with SHA-256
  `32ea3730be90665e54ee0126c63b1b85a01000f5ab57f92618cf26bd725bc490`;
- an unmodified, signed, and notarized stable desktop host `0.0.403`
  (Electron `42.7.1`, Chromium `148.0.7778.280`, native updater build
  `87263`) installed by Discord's current official distribution into an
  isolated temporary profile so the installed Equicord app was not targeted;
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

The clean desktop observation covered sign-in restoration, Gateway startup,
opening a public guild and its default channel, history loading, and a renderer
reload. Selecting the guild caused one newest-history GET and no read
acknowledgement. The reload rebuilt account and guild state from Gateway rather
than issuing `/users/@me` or `/users/@me/guilds`; it also performed the
first-party lurker-membership mutation for that public guild. SakuraCord does
not copy unrelated store, billing, analytics, experiment, or lurker-join
fan-out. No message, reaction, acknowledgement, call, or other user-content
mutation was sent during the observation.

### Evidence priority for protocol changes

Every new or materially changed production communication with Discord must be
cross-referenced against all of these sources:

1. current public Discord documentation where applicable;
2. the current official production web-client bundle;
3. the pinned Paicord implementation;
4. the pinned Swiftcord v1 implementation; and
5. a clean current official-client observation when the static sources leave a
   material ambiguity.

The official web bundle is the primary operational source for undocumented
normal-user client behavior because it exposes first-party route constants,
request construction, state ownership, and Gateway reconciliation. It remains
minified, changeable, and unsupported as a public contract, so record its build
or asset hash and observation date. Paicord and Swiftcord are mandatory
cross-checks, not substitutes for first-party evidence; record explicitly when
one has no comparable path. Public documentation remains authoritative for
supported API semantics, status codes, and rate limits.

Implement the exact current first-party request and event shape unless
SakuraCord has a deliberate safety or architectural difference. Every
difference must be explained with evidence and locked down by mocked
request-contract and request-budget tests.

## Current production capability gates

`DiscordRESTProvider.supports(_:)` is the authority:

| Capability | Production provider | Offline provider |
| --- | --- | --- |
| Forum channels | Enabled | Enabled |
| Slash commands | Enabled | Enabled |
| Message components and returned modals | Disabled | Enabled with fixtures |
| Remote component choices | Disabled | Enabled with local fixtures |
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
- sanitized route/status/bucket logging;
- a bounded session-local diagnostics export covering REST attempts and
  responses, attachment uploads, native authentication, and main, voice, and
  remote-auth Gateway envelopes; and
- one provider-wide safety circuit shared with the Gateway session.

Normal cold startup is Gateway-first. `READY.user`, `READY.guilds`,
`READY.private_channels`, settings, read state, and the supplemental payload
seed the account before the first snapshot is published. A complete Ready
therefore sends zero `/users/@me` and zero `/users/@me/guilds` reads. In the
sanitized 4 August 2026 large-account desktop observation, Ready carried all 16
guild IDs and their channel collections but omitted the guild names needed for
the catalogue. SakuraCord used one bounded `/users/@me/guilds` fallback after a
server `429`; the decoded settings contained 12 folders covering 15 guilds.
That layout must remain pending until the fallback catalogue is installed, then
order the live rail instead of being consumed against an empty catalogue. The
two REST routes remain sequential, bounded compatibility fallbacks when Ready
omits required data, except that `/users/@me` is available only to a previously
stored session. A newly authenticated session requires `READY.user` before it
persists the credential and never falls back to that route. This matches the
current official login and Swiftcord v1's pending-token flow. Paicord's stores
are Gateway-owned after connection, but its login view model is the documented
outlier that reads `/users/@me` before storing an account. Paicord also treats
the Ready settings proto as the authoritative guild-folder order.

The 3 August 2026 first-party web asset defines the Apex experiment surface
`APP` as integer `2` and sends that value on the current login path. A sanitized
unauthenticated production check returned `400` / Discord error `50035` for the
obsolete string `discord_app`, while `surface=2` returned `200` with the
expected installation field. Discord's public API documentation, pinned
Paicord, and pinned Swiftcord v1 have no corresponding Apex implementation.

### Audited HTTP route surface

This is the complete production Discord HTTP surface reachable from the
current app. Optional keys are omitted from JSON rather than encoded as null
unless the row says otherwise. `P−` and `S−` mean the pinned Paicord or
Swiftcord v1 revision has no corresponding implementation; absence was checked
and retained as evidence.

| Method and route template | Trigger and exact supported request shape | Cross-reference result |
| --- | --- | --- |
| `GET /apex/experiments?surface=2` | Cold native password/MFA installation preflight, or one stored-session repair when an older credential lacks its installation identity; unauthenticated, no body, Authorization, fingerprint, installation header, or heartbeat session. Only the returned installation ID is retained. The obsolete string surface is rejected with `400` / `50035`. | Current official login; P−, S−. |
| `GET /experiments?with_guild_experiments=true` | Cold native password/MFA fingerprint preflight only; unauthenticated, no body, carries the server-issued installation ID and `X-Context-Properties` location `Login`. Stored-session repair does not repeat this request. | Current official login and Paicord; Swiftcord v1 has no native-login counterpart. Paicord lacks the current Apex preflight and query/context shape. |
| `POST /auth/login` | Explicit login; `login`, `password`, `undelete:false`, `login_source:null`, and `gift_code_sku_id:null`; one user-completed CAPTCHA replay may add challenge headers. | Current official live password login and web action; Paicord omits the null keys; S−. |
| `POST /auth/mfa/{totp,sms,backup}` | Explicit MFA; `code`, `ticket`, optional `login_instance_id`, `login_source:null`, and `gift_code_sku_id:null`. | Current official web action and Paicord; no live MFA challenge occurred in the 3 August clean-client pass; S−. |
| `POST /auth/mfa/sms/send` | Explicit SMS choice; `ticket`. | Current official and Paicord; S−. |
| `POST /users/@me/remote-auth/login` | Approved QR ticket exchange; `ticket`; at most one user-completed CAPTCHA replay. | Current official remote-auth v2 and Paicord; S−. |
| `GET /users/@me` | Incomplete-Ready compatibility fallback for a previously stored session only; no body. A newly authenticated session fails closed if Ready omits its user and never sends this route. | Public user semantics and Paicord. Current official login and Swiftcord v1 obtain the authenticated user from Gateway Ready; Paicord login performs this extra read. |
| `GET /users/@me/guilds` | Incomplete-Ready compatibility fallback only; no body. | Public guild semantics; normal current official/Paicord/Swiftcord startup uses Gateway instead. |
| `GET /guilds/{guild}/channels` | Cache-miss fallback only; no body, coalesced by guild. | Public channel semantics and all three client references. |
| `GET /guilds/{guild}/roles` | Visible role/member UI cache miss; no body, coalesced. | Public guild semantics and all three client references. |
| `GET /guilds/{guild}/roles/{role}/member-ids` | Explicit role inspection; no body; result display capped at 1,000. | Current first-party route; P−, S−. |
| `GET /users/{user}/profile` | Explicit profile; `with_mutual_guilds=true`, `with_mutual_friends=true`, `with_mutual_friends_count=true`, plus `guild_id` only in guild context; coalesced by user and guild context. | Current first-party and Paicord; Swiftcord has historical profile data but no equivalent complete route. |
| `GET /collectibles-products/{product}` | At most one cache-miss read for a profile effect returned by the profile response; query contains the current `locale`. | Current first-party route; P−, S−. The obsolete `/user-profile-effects` fallback was removed. |
| `GET /guilds/{guild}/emojis` | Stale/missing Gateway and disk-cache fallback; no body, coalesced. | Public emoji semantics and all three client references. |
| `GET /users/@me/settings-proto/2` | Explicit emoji-settings cache miss; no body, coalesced for the provider session. | Current first-party, Paicord, and Swiftcord's versioned settings-proto path. |
| `GET /channels/{channel}/messages` | Visible history only; guild history requires effective `VIEW_CHANNEL` and `READ_MESSAGE_HISTORY`, and voice-channel history additionally requires `CONNECT`. The current clean client uses `limit=10` for a newly selected uncached channel, which SakuraCord matches once per channel per uninterrupted Gateway connection. Reopening a loaded channel restores its bounded session-memory page and sends no history request. After a Gateway gap, the retained page is presented immediately but its completeness marker is invalidated; returning to Ready refreshes the selected page once and later reopened pages refresh once on selection. Older-page pagination uses ordered `before` then `limit=50`; no body. | Public message semantics, current first-party permission/message paths and stale-connection refresh, and Paicord's permission-checked channel store. Swiftcord v1 checks `VIEW_CHANNEL` before presentation but otherwise supplies only a historical unguarded/refetching history path. Paicord retains a per-channel in-memory store and uses a historical 50-message initial page. The current first-party cache behavior and connection-generation invalidation take precedence. |
| `GET /channels/{thread}` | One unknown-thread deep-link resolution; no body. | Public channel semantics and all three references. |
| `POST /channels/{forum}/threads?use_nested_fields=true` | Explicit forum creation; `name`, `auto_archive_duration`, ordered `applied_tags`, nested `message` with `content`, `sticker_ids:[]`, and attachments only when uploaded. | Current first-party action; Paicord and Swiftcord have only partial/historical thread creation. |
| `GET /channels/{forum}/threads/search` | Forum catalogue: `archived=true`, `sort_by`, `sort_order=desc`, `limit`, `offset`, and optional `tag`/`tag_setting`; name search adds `name`. | Current first-party route; P−, S−. |
| `POST /channels/{forum}/post-data` | Preview hydration with `thread_ids` batches of at most ten. | Current first-party route; P−, S−. |
| `PATCH` or `DELETE /channels/{thread}` | One explicit forum metadata mutation or deletion; partial body for the selected action only. | Current first-party and public channel semantics; partial Paicord/Swiftcord coverage. |
| `POST /channels/{thread}/thread-members/@me?location=Change%20Notification%20Settings` | One join only when changing settings for an unjoined post; empty body. | Current first-party route; P−, S−. |
| `PATCH /channels/{thread}/thread-members/@me/settings` | Explicit thread notification change; only reviewed `flags`, `muted`, and `mute_config` keys. | Current first-party route; P−, S−. |
| `POST /channels/{channel}/typing` | Empty body after the local 1.5-second delay and eight-second coalescing window. | Public typing semantics and all three references. |
| `POST /channels/{channel}/messages/{message}/ack` | One viewport-qualified acknowledgement; `token` is always present (null before Discord issues one), `last_viewed` is the current Discord-epoch day, and `flags` is sent only when the recomputed guild/thread value differs from Ready state. Manual-unread fields remain explicit-action-only. | Current first-party and Paicord; S−. |
| `PATCH /users/@me/guilds/{guild-or-@me}/settings` | One explicit notification change; a single partial `channel_overrides` entry. | Current first-party; P− and S− for the private `@me` scope. |
| `GET /guilds/{guild}/application-command-index`, `/channels/{channel}/application-command-index`, `/users/@me/application-command-index`, or `/applications/{application}/application-command-index` | Target-specific index; at most three created GETs for the reviewed `202`/`429` readiness flow. | Current first-party route family; P−, S−. |
| `POST /interactions` | One explicit type-2 execution, type-4 autocomplete, or returned modal submission; nonce-keyed, one attempt. | Current first-party and Paicord command model; Swiftcord has no current index/interaction path. |
| `POST /channels/{channel}/messages` | One explicit send; `content`, nonce, `tts:false`, `flags:0`, macOS `mobile_network_type:"unknown"`, optional reply/attachments, and `X-Context-Properties` location `chat_input`. SakuraCord deliberately adds `enforce_nonce:true`. | Current first-party build and clean macOS Network Information result; Paicord supplies the nonce-oriented reference; Swiftcord is historical and nonce-less. |
| `POST /channels/{channel}/attachments` | Explicit files only; `files` entries contain string index `id`, `filename`, `file_size`, and `is_clip:false`. | Current first-party upload action and Paicord; Swiftcord has no comparable presigned upload. |
| `PUT {Discord-issued upload_url}` | One unauthenticated storage PUT per reserved file, `application/octet-stream`, raw bytes, no Discord authorization metadata. | Current first-party and Paicord; S−. |
| `PATCH` or `DELETE /channels/{channel}/messages/{message}` | Explicit edit with only `content`, or explicit deletion with no body. | Public message semantics and all three references. |
| `PUT` or `DELETE /channels/{channel}/messages/{message}/reactions/{emoji}/@me` | One coalesced explicit reaction intent; empty body. | Public reaction semantics and all three references. |
| `GET /channels/{channel}/messages/{message}/reactions/{emoji}` | Visible reactor preview only; `type=0&limit=5`, no pagination. | Public reaction-user semantics and current first-party; Paicord/Swiftcord provide historical reaction reads. |
| `GET /channels/{dm}/call` | One-to-one explicit call start readiness read only; no body. | Current first-party; P−, S− for the current readiness contract. |
| `POST /channels/{dm}/call/ring` | Explicit call start after pushed call creation; `recipients:null` or the explicit recipient list. | Current first-party; Paicord partial, S−. |
| `POST /channels/{dm}/call/stop-ringing` | Explicit decline; nonempty `recipients` list. | Current first-party; Paicord partial, S−. |

Shared request metadata now matches the non-secret fields observed from the
clean host: product OS version rather than Darwin kernel version, actual system
locale, Chromium's ordered language preference header, current client/build
versions, `client_event_source:null`, and client-generated launch,
launch-signature, and heartbeat-session identifiers. `client_app_state`
follows the real main-window focused/unfocused state. The current host includes
`native_build_number:87263`. Pre-login authentication carries the legitimately
issued fingerprint and installation ID, but omits
`client_heartbeat_session_id` until Gateway startup, matching the clean host.
Successful authentication clears the fingerprint before Gateway startup and
subsequent production REST requests while the persisted installation ID
remains in `X-Installation-ID`, matching the clean client. `X-Routing-Key`
remains absent for normal users; the first-party value is a staff/developer
override, not a client-generated identifier.

Diagnostics payloads are allowlisted and redacted before they enter the
in-memory store. The export may retain protocol metadata and snowflake IDs, but
never retains credentials, cookies, challenge values, message content, names,
usernames, profile text, filenames, or URLs. It is a debugging record of the
current app session, not an unbounded traffic archive.

The default attempt budget is exact:

| Operation | Maximum attempts |
| --- | ---: |
| Ordinary authenticated GET | 2; the second attempt occurs only after a server `429` cooldown. |
| Authenticated mutation | 1; no automatic replay after `429`, timeout, or ambiguous failure. |
| Application-command index readiness | 3 created GETs for the separately tested `202`/`429` flow. |
| Cold native installation/fingerprint preflight status retry | Original plus at most 3 bounded retries for `429`, `500`, `502`, or `504`, subject to the established delay ceiling. |
| Stored-session missing-installation repair | 1 unauthenticated Apex GET; no automatic retry. |
| Native password/MFA status retry | Original plus at most 2 current-official retries for `429`, `500`, `502`, or `504`, subject to the established delay ceiling. |
| Remote-auth ticket status retry | Original plus at most 3 Paicord-policy retries for `429`, `500`, `502`, or `504`, subject to its delay ceiling. |
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

`GatewaySession` is the sole socket owner. Production uses the clean desktop's
API v9 ETF encoding with `zstd-stream`. JSON with `zlib-stream` remains only as
an injectable deterministic test transport and as the historical web/Swiftcord
cross-reference.

Each zstd WebSocket message is decompressed through one connection-lifetime
context and is drained until both its compressed input and any pending decoder
output are exhausted. Consuming the final input byte is not sufficient when
the decoder filled its output buffer. Discord's current Gateway documentation
requires repeated `ZSTD_decompressStream` calls and explicitly notes that its
return value need not reach zero; pinned Paicord likewise continues whenever
its destination buffer is full. Swiftcord v1/DiscordKit uses JSON with zlib and
has no zstd counterpart. A sanitized 4 August 2026 live startup exposed the
regression as exactly 589,824 partial bytes (nine 64 KiB chunks) from a large
ETF Ready payload; the corrected decoder retains the existing 8 MiB compressed
and 16 MiB decompressed safety bounds.

ETF maps may use 64-bit integer keys even though the equivalent JSON object can
only expose string keys. The clean 4 August large-account Ready payload did so;
SakuraCord now converts integer keys to their exact decimal spelling without a
floating-point round trip. This follows Discord's documented ETF rule that
snowflakes may be 64-bit integers or strings and produces the same object-key
shape consumed by the JSON web, Paicord, and Swiftcord paths.

The same rule applies to ETF integer values outside JavaScript's exact integer
range: they are normalized to exact decimal strings before DTO decoding rather
than passing through `Double`. Safe-range counters and timestamps remain JSON
numbers. This preserves guild, channel, user, message, and role snowflakes on
large Ready payloads while matching the JSON representations used by the other
reviewed clients.

ETF `STRING_EXT` is normalized as the byte-list it represents, not as UTF-8
text. A sanitized 4 August 2026 desktop session used that compact term for the
two-integer `range` in `GUILD_MEMBER_LIST_UPDATE`; treating it as text caused
the complete member-list update to fail decoding. The resulting JSON array
matches the current first-party JSON shape and pinned Paicord's `IntPair`.
Swiftcord v1 has no corresponding member-list implementation.

The state machine covers:

```text
disconnected -> connecting -> awaitingHello -> identifying -> ready
                                             -> resuming   -> ready
connecting/awaitingHello/identifying/resuming/ready -> backingOff -> connecting
any state -> stopped
```

Durable requirements:

- one Identify or Resume after each new Hello;
- a randomized first heartbeat and current desktop QoS opcode-40 heartbeats;
- ACK tracking and reconnect after a missed ACK;
- in-memory session ID, resume URL, and sequence for same-process Resume;
- Resume before a fresh Identify when state is valid;
- explicit invalid-session and close-code handling;
- bounded, jittered reconnect backoff;
- a connection generation that prevents stale tasks from affecting a new
  socket; and
- explicit stop/logout with no reconnect.

The complete outgoing main-Gateway opcode surface is 2 Identify, 3 presence, 4
voice state, 6 Resume, 8 bounded guild-member request/search, 13 private-call
subscription, 37 bulk guild subscription, 40 QoS heartbeat, and 41 time-spent
session update. After Ready, the desktop lifecycle order is 4 (null voice
state), 3 (current presence), 41, then 40. QoS payloads use version 29 and only
the locally known `foregrounded` reason; heartbeat sessions rotate after 30
minutes inactive and the REST super-properties update with the same session.
Paicord supplies current JSON/zstd and 40/41 cross-checks. Swiftcord v1 supplies
the historical JSON/zlib and opcode-1 subset and has no 13, 37, 40, or 41.

Current first-party Identify normally uses capability bitfield `1734653`; the
clean account received `1767421` because the first-party
`private_channel_obfuscation` experiment adds bit 15. SakuraCord deliberately
does not advertise that dynamic bit until it implements the corresponding
obfuscated-private-channel reconciliation. This is the remaining Gateway
metadata difference and prevents requesting a payload shape the app cannot yet
consume.

### Dispatch reconciliation

The complete inbound dispatch surface was rechecked on 3 August 2026 against
Discord's current public Gateway event catalogue, public web build `587597`
and asset `web.a8c0f0f55a5a68c4.js`, Paicord revision
`694761c1938b73bb60bd58942674dfe73aab1135`, Swiftcord v1 revision
`14465d927ebe1ba34b3befa00f9365fad7b56eb9`, and DiscordKit revision
`2d42c69cafe592300a1a9d3a307bf485294026c7`. The official asset's route
converters and stores resolved the event shapes and cache ownership without a
material ambiguity, so this pass required no authenticated action or new live
traffic capture. Paicord decodes the current lifecycle and secondary-feature
families. Swiftcord v1 and DiscordKit provide historical lifecycle coverage but
omit several newer voice, AutoMod, entitlement, subscription, and event-
exception dispatches.

- `GUILD_CREATE` adds or restores the guild, its rail entry, channels, roles,
  members, threads, emoji, and voice state. `GUILD_UPDATE` patches every guild
  field SakuraCord models. `GUILD_DELETE` with `unavailable:true` retains and
  marks the guild unavailable; an ordinary delete removes its guild-scoped
  caches, requests, channels, and rail entry. Joining, becoming unavailable,
  recovering, and leaving issue no compensating REST request.
  A 4 August 2026 follow-up found that desktop ETF can represent a permission
  bitfield as an integer even though Discord's public JSON guild schema uses a
  string. Gateway Ready and Guild Create decoding therefore accept either
  representation. A numeric-permissions Guild Create fixture proves the new
  guild and rail entry are reconciled without a REST fallback.
- Guild `CHANNEL_CREATE`, `CHANNEL_UPDATE`, and `CHANNEL_DELETE` reconcile a
  raw per-guild channel catalogue before rebuilding presentation. This retains
  categories, positions, permission overwrites, pins, and voice metadata, so a
  permission or category change takes effect without a channel-list reload.
  `GUILD_ROLE_*`, `GUILD_MEMBER_*`, and `USER_UPDATE` likewise update the
  shared role, member, permission, current-user, DM-recipient, and loaded-
  message projections without a REST probe.
- `MESSAGE_DELETE_BULK` removes every named loaded message and publishes the
  same per-message deletion boundary as a single delete.
  `CHANNEL_PINS_UPDATE`, `THREAD_MEMBERS_UPDATE`,
  `VOICE_CHANNEL_STATUS_UPDATE`, and `VOICE_CHANNEL_START_TIME_UPDATE` update
  their cached channel or thread fields in place. Voice start times accept the
  documented Unix-seconds representation; ISO timestamps remain a lossless
  compatibility input for first-party-normalized channel objects.
- A `RATE_LIMITED` dispatch records Discord's `retry_after` seconds against
  the rejected outgoing opcode. A send attempted during that cooldown fails
  locally, and a rejected member request completes its pending continuation
  with an error. SakuraCord does not replay, retry early, or speculate about a
  replacement Gateway request.
- Sticker, soundboard, scheduled-event and exception, Stage, poll-vote,
  integration, webhook, AutoMod, entitlement, and subscription dispatches have
  no production state consumer. They are deliberately ignored after sanitized
  transport diagnostics instead of occupying the application event stream or
  maintaining unused caches. They do not enable an unsupported feature, add
  fan-out, or trigger an authenticated read.

All of these paths use sanitized deterministic dispatch fixtures. Their
request budget is zero: a received dispatch mutates local state and never
creates a REST request or an additional outgoing Gateway payload.

### Other Discord transports

The HTTP table above is the complete API REST and issued-upload surface, but it
is not the whole network surface. The remaining production connections are:

- the main Gateway WebSocket at `wss://gateway.discord.gg` (or the
  server-provided resume URL) with the exact `v=9`, `encoding=etf`, and
  `compress=zstd-stream` query. It carries only the outgoing opcodes listed
  above and decodes pushed dispatches into the shared cache/state model;
- the unauthenticated remote-login WebSocket at
  `wss://remote-auth-gateway.discord.gg/?v=2`. It uses an ephemeral URL session
  without cookie storage, an ephemeral RSA key, and the reviewed User-Agent,
  Origin, Cache-Control, and Accept-Language headers. It never receives the
  account authorization token; only the server-issued ticket is exchanged by
  the central authenticated REST transport after user approval;
- a voice Gateway WebSocket at the endpoint supplied by
  `VOICE_SERVER_UPDATE`, normalized to `wss://{endpoint}?v=8`, followed by UDP
  discovery and encrypted RTP to the server-supplied IP and port. This path is
  reached only by an explicit voice/call action and uses the existing
  DAVE-capable voice state machine; and
- unauthenticated HTTPS media GETs to `cdn.discordapp.com` and
  `media.discordapp.net` for server-returned or locally derived Discord asset
  paths. These loads use an isolated ephemeral URLSession with memory-cache
  semantics and cookie storage explicitly disabled. They carry no
  Authorization, client-properties, fingerprint, installation ID, or
  routing-key headers and use a shared coalescing/cancellation queue. Inline
  linked images are accepted only on those exact HTTPS hosts, without
  credentials or a custom port; SakuraCord does not fetch arbitrary
  third-party link previews.

The current official desktop and SakuraCord use ETF with `zstd-stream` for the
main Gateway. The public web client uses JSON with compressed Gateway
transport, Paicord uses JSON plus zstd, and Swiftcord v1 uses historical JSON
plus zlib.

## Authentication

Native authentication is implemented without an embedded Discord login page:

- a cold password login performs the Apex installation preflight, the
  installation-bearing fingerprint preflight, login, then connects Gateway;
- a warm password login performs login and then connects Gateway;
- a stored credential missing only its installation identity performs one
  unauthenticated Apex lookup and then connects Gateway without repeating the
  fingerprint or login requests;
- MFA adds one explicit verification request;
- hCaptcha is completed by the user and permits one challenged-request replay;
- QR login uses one remote-auth v2 WebSocket, an ephemeral RSA key, one ticket
  exchange, then connects the main Gateway after approval; and
- the returned credential remains memory-only until `READY.user` supplies a
  valid account ID, at which point it enters `KeychainCredentialStore` exactly
  once. Cancellation, bootstrap failure, or an omitted Ready user discards it.

Passwords, challenge solutions, and credentials are never written to
preferences, fixtures, GRDB, or logs. The server-issued fingerprint and
installation ID are persisted only in local preferences to reproduce the
first-party lifecycle; neither value is logged or committed. A cancelled or
rejected challenge does not create another request.

The clean desktop additionally read `/auth/location-metadata` for its own
country, consent, and promotional UI and emitted science traffic before the
user submitted the form. SakuraCord has no corresponding UI or analytics
consumer, so it deliberately does not add those unrelated requests. The clean
success path connected Gateway immediately after `/auth/login`; SakuraCord now
uses that same ordering. Swiftcord v1 independently corroborates the pending
token → Gateway Ready user → account-store sequence. Paicord performs an extra
pre-Gateway current-user read and was retained only as conflicting evidence,
not copied into the production path.

## Established feature contracts

These summaries preserve the durable network behavior from the consolidated
implementation records.

### Messages, typing, mentions, and links

- Process startup never presents a persisted Discord workspace or message
  page. A data-free full-layout skeleton remains visible until the live Ready
  bootstrap is applied. Message pages, pagination boundaries, prepared rows,
  and Gateway deltas are retained only in bounded process memory. Reopening a
  loaded channel therefore issues zero history requests, while relaunching the
  app deliberately starts empty and performs the one reviewed `limit=10`
  newest-page read after Ready. The 3 August first-party bundle performs its
  initial read only for an uncached selection. Pinned Paicord retains one
  `ChannelStore` per channel and likewise reuses it on selection; pinned
  Swiftcord v1 is the historical outlier that clears and refetches on every
  channel change. Discord's public message documentation defines the endpoint,
  permissions, and pagination parameters but does not prescribe client cache
  lifetime.
- One user send creates one message POST with a Discord-epoch nonce,
  `enforce_nonce: true`, `tts: false`, `flags: 0`, the clean macOS host's
  `mobile_network_type: "unknown"`, attachments only when present, and
  `chat_input` context.
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
- `MESSAGE_REACTION_ADD`, `MESSAGE_REACTION_REMOVE`,
  `MESSAGE_REACTION_REMOVE_ALL`, and `MESSAGE_REACTION_REMOVE_EMOJI` apply
  typed deltas to loaded messages without a history reload. Current-user normal
  and burst state are reconciled independently so the Gateway echo of one
  optimistic REST toggle cannot change the aggregate count twice. Each delta
  fans out to visible, session-cached, thread, and forum-preview message
  state without issuing another authenticated request. The typed reaction
  event is the sole presentation delta; updating the provider's forum cache
  does not also publish a catalogue replacement for the same Gateway event.
- A reaction click changes local presentation immediately. Intents are
  coalesced independently by channel, message, and emoji; only the latest
  desired reacted/unreacted state is sent after the short local debounce.
  Each key permits one mutation in flight and at most one coalesced follow-up
  when its desired state changes during that request. PUT and DELETE mutations
  have one attempt, are never retried after an ambiguous failure, and roll back
  only that key when Discord does not confirm the requested state.
- Rich rendering issues no authenticated request by itself. Link previews use
  decoded embeds; SakuraCord does not scrape or preflight message URLs.
- Reactor previews use the documented reaction-user GET with `type=0&limit=5`.
  Loads are visible-row driven, coalesced, cached, limited to four concurrent
  reads, and never paginate. The preview identity is stable across count
  changes, loaded reactor avatars remain visible while REST and Gateway
  reaction state reconciles, and hover is only a tooltip trigger rather than a
  data-loading prerequisite.
- Forum cards summarize the starter message with its highest-count active
  reaction, preserving Discord source order as the tie-breaker. With no active
  reactions they show the configured default emoji without a numeric zero.
  Partial catalogue and preview-hydration payloads preserve richer loaded
  reactor identities instead of replacing them with an empty preview.
- A 26 July 2026 read-only comparison with Equicord WhoReacted revision
  `1e353f3bdea3545c198b32c7e2216fcd0b923dbf` confirmed the presentation
  pattern: fetch once through a shared queue, retain reactor identities in a
  message-and-emoji cache, and rerender from that cache independently of hover.
  SakuraCord implements that behavior in its native model and bounded
  five-reactor cache; no Equicord source was copied.
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
- A forum channel's `last_message_id` is its newest thread ID. Because Discord
  does not send a parent `CHANNEL_UPDATE` for that change, `THREAD_CREATE` and
  `THREAD_LIST_SYNC` advance the cached parent boundary before unread
  presentation is recomputed.

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
- Selecting accessible voice-channel text chat uses the ordinary one-page
  message-history read and does not join voice. Effective `VIEW_CHANNEL`,
  `READ_MESSAGE_HISTORY`, and `CONNECT` are required before that read;
  reopening an already open pane adds no request.

### Guild metadata and member lookup

- Community rules-channel presentation uses the guild's authoritative
  `rules_channel_id`, not a channel name or UI heuristic, and adds no request.
- Role-color presentation uses the enhanced role-colors object's
  `primary_color`, falling back to the deprecated top-level `color` field for
  compatibility. This was rechecked on 31 July 2026 against Discord's public
  guild-resource documentation and public web asset
  `web.505415119e321976.js`; the web client writes both fields and reads the
  enhanced colors for role presentation. Pinned Paicord revision
  `694761c1938b73bb60bd58942674dfe73aab1135` and Swiftcord v1 revision
  `14465d927ebe1ba34b3befa00f9365fad7b56eb9` model only the legacy field.
  Decoding or displaying either form adds no request.
- Chat author presentation retains per-guild role and member stores across
  channel selection. A virtualized member-list range cannot evict members
  outside that range, while an authoritative update replaces the stored role
  list so a removed role cannot leave a stale color behind. This matches
  Paicord's `GuildStore`/`MessageAuthor` ownership. When a guild history page
  contains an author absent from that store, SakuraCord performs at most one
  Gateway opcode 8 request for at most 100 unique user IDs, with authors
  prioritized before mentions and `presences: false`. The request deliberately omits `nonce`, as
  do Discord's current `requestGuildMembers` implementation and pinned
  Paicord; the response is reconciled against its guild plus the union of
  returned member IDs and `not_found` IDs. IDs already cached or requested in
  the current Gateway session are omitted. The same bounded lookup also runs
  after locally persisted rows are merged, matching the official web client's
  `LOCAL_MESSAGES_LOADED` branch instead of limiting hydration to
  `LOAD_MESSAGES_SUCCESS`. Reply authors share that request budget. The
  returned raw role IDs are retained on both the member and history message so
  later virtualized member-list ranges cannot evict the author's role data.
  This was rechecked on 31 July 2026 against Discord's public Request Guild
  Members contract, current public web asset `web.505415119e321976.js` module
  `860071`, and pinned Paicord
  `ChannelStore.fetchMessages`/`GuildStore.requestMembers`. Discord's client
  requests missing history authors and mentions through a deduplicating member
  requester; Paicord performs the same post-history lookup. Pinned Swiftcord v1
  has no corresponding missing-author hydration path. A cache-disabled CDP
  recheck against Discord stable desktop host `0.0.402` on 31 July 2026 found
  that fresh
  `GET /channels/{channel_id}/messages?limit=...` responses were HTTP 200 reads
  with no request body, no `guild_id`, and no `member` object on any returned
  message. The freshly restarted official client nevertheless rendered a
  sampled author's non-default role color from its initial compressed Gateway
  member state; it did not need a subsequent opcode 8 request for that sampled
  author. SakuraCord therefore treats Gateway membership as authoritative,
  marks it usable in the validated `READY` dispatch before bootstrap can
  resume, and removes failed author IDs from the request-deduplication set so a
  connection-timing failure cannot permanently suppress their later lookup.
  An authenticated, sanitized SakuraCord trace in the Swiftcord `#general`
  channel on 31 July 2026 exposed the prior defect precisely: Discord returned
  valid chunks containing 6 and 11 requested members with no nonce, while the
  client rejected them and timed out. The old client had sent a hyphenated UUID
  nonce (36 bytes); Discord's public contract caps nonces at 32 bytes and states
  that an invalid nonce is ignored and omitted from the response. The current
  implementation removes that invalid field, matches the first-party and
  Paicord request shape, and reconciles the observed nonce-less response by
  guild plus the returned and `not_found` user IDs.
- The channel member inspector keeps the official client's single initial
  `0...99` member-list range and treats `GUILD_MEMBER_LIST_UPDATE.groups` as
  the authority for group order and counts. Loaded member rows retain their
  Gateway order; SakuraCord does not infer totals from the virtualized slice.
  This was rechecked on 31 July 2026 against public web asset
  `web.505415119e321976.js` and pinned Paicord's member-list store. Discord's
  public Gateway documentation does not describe opcode 37 or this dispatch;
  Swiftcord v1 has no corresponding implementation. The change adds no
  request and preserves the existing one-payload subscription budget.
- Hidden-channel metadata and effective access are derived from cached guild,
  role, member, and permission-overwrite data. Displaying the last-message
  snowflake time or allowed overwrite identities does not load hidden content.
- Opening a role reads one member-ID list, resolves missing users through
  Gateway member requests in batches of at most 100, and displays at most 1,000
  members. Cached members remove the corresponding Gateway batches.
- Ready read state admits only `read_state_type == 0` channel entries. If the
  payload repeats a channel entry, the newest payload-order entry wins instead
  of crashing dictionary construction.

### Unread state, acknowledgements, and notifications

The durable baseline was rechecked on 2026-07-27 against Paicord revision
`694761c1938b73bb60bd58942674dfe73aab1135`, Swiftcord v1 revision
`14465d927ebe1ba34b3befa00f9365fad7b56eb9`, current Discord desktop
presentation, clean public web build 582977, and Discord's public message,
guild, thread, and notification-setting documentation. The desktop-host caveat
in the evidence snapshot still applies; no authenticated traffic was
intercepted for this recheck. Paicord and Swiftcord v1 have no comparable forum
new-post implementation.

The read-state transport and reconciliation path was rechecked again on
2026-07-31 against clean public web asset `web.c01c1db6d97b320d.js`, the same
pinned Paicord and Swiftcord revisions, and Discord's public Gateway,
message, status-code, and rate-limit documentation. The public documentation
does not describe the user-client acknowledgement route or `MESSAGE_ACK`
dispatch. The web asset and Paicord both carry a version on Ready read state
and `MESSAGE_ACK`; Swiftcord v1 has no comparable acknowledgement mutation or
Gateway reconciliation path. No authenticated account action or traffic
capture was used for this recheck.

- Account-scoped channel read state combines Ready `read_state` with each
  channel's authoritative `last_message_id`. Message and acknowledgement
  snowflakes are compared numerically, and live `MESSAGE_CREATE` and
  `MESSAGE_ACK` events update the same monotonic model. A successfully loaded
  newest history page also advances the known latest-message boundary, so a
  stale channel object cannot make an opened conversation acknowledge an older
  message than the one actually displayed. Read states for channels
  without effective `VIEW_CHANNEL` and `READ_MESSAGE_HISTORY` access are
  excluded from channel, guild, folder, and Dock-badge presentation.
  A channel, thread, or forum post omitted from Ready's channel read-state
  entries begins at the supplied `last_message_id` as read; it does not become
  unread merely because history or a thread catalogue was loaded. This
  deliberately differs from Paicord's missing-entry fallback and matches
  Swiftcord v1 plus the official desktop client's authenticated guild
  indicators observed on 2026-07-25. A later accepted `MESSAGE_CREATE` still
  makes that conversation unread immediately.
- The authenticated workspace remains in its connecting presentation until the
  initial Ready dispatch has been decoded. Its first bootstrap snapshot
  atomically includes known DMs, guild channels, threads, channel read states,
  and guild notification settings; these values must not race a later event
  into the first sidebar render.
- Current Ready payloads wrap `user_guild_settings` in an object containing
  `entries` and `partial`; the legacy top-level array remains accepted. The
  separate `notification_settings.flags` bit 4 (`USE_NEW_NOTIFICATIONS`) is
  part of unread resolution and must not be inferred from guild settings.
- A user-selected per-channel notification or mute change sends one immediate
  `PATCH /users/@me/guilds/{guild_id_or_@me}/settings` through the central
  transport. Guild channels use their guild ID, while direct and group-DM
  channels use `@me`; Ready and Gateway settings represent that private-channel
  scope with a null guild ID.
  Its partial body contains only the selected channel in `channel_overrides`;
  notification levels use Discord's `0` (all), `1` (mentions), `2` (nothing),
  and `3` (inherit) values, while mute updates pair `muted` with a bounded
  `mute_config.end_time` or `null` for a permanent mute. The mutation has one
  attempt, is applied locally only after success, and is subsequently
  reconciled by authoritative `USER_GUILD_SETTINGS_UPDATE` events. This
  contract was statically rechecked on 2026-07-30 against Paicord revision
  `694761c1938b73bb60bd58942674dfe73aab1135`, Swiftcord v1 revision
  `14465d927ebe1ba34b3befa00f9365fad7b56eb9`, and Discord's clean public web
  asset `web.b79b97dbe82a637e.js`. The pinned Paicord and Swiftcord revisions do
  not implement the corresponding private-channel settings mutation; the
  `@me` scope follows Discord's current public asset, which routes null or
  `@me` user-guild settings through `USER_GUILD_SETTINGS(@me)` rather than the
  bulk guild endpoint. No authenticated account action or traffic capture was
  used.
- Forum-post notification settings are current-user thread-member state, not
  parent-forum channel overrides. Joined posts send one
  `PATCH /channels/{thread_id}/thread-members/@me/settings`; an unjoined post
  first sends one
  `POST /channels/{thread_id}/thread-members/@me?location=Change%20Notification%20Settings`,
  then the same single-attempt settings patch. Notification selection preserves
  unrelated member flags while replacing bits `2` (all messages), `4` (mentions),
  and `8` (nothing), with no selected bit meaning inherit. Mutes send `muted`
  with a bounded `mute_config.end_time` or `null`. Inline thread members,
  `THREAD_LIST_SYNC.members`, and `THREAD_MEMBER_UPDATE` reconcile the displayed
  `flags`, `muted`, and `mute_config`. This contract was statically checked on
  2026-07-30 against Discord's clean public web asset
  `web.b79b97dbe82a637e.js`; Discord's public Gateway and thread documentation
  confirms that sync members belong to the current user and that
  `THREAD_MEMBER_UPDATE` carries that user's thread member, but does not
  document the user-client settings patch. Pinned Paicord and Swiftcord v1 do
  not implement these post notification controls. No authenticated request was
  sent.
- A conversation becomes locally read only after its initial history is
  loaded, the timeline has established its real initial position, the bottom
  edge of its newest message is inside the native viewport, and the main window
  is active. An unread conversation initially presents its first loaded unread
  message. If the complete unread run fits in that viewport, its newest edge is
  visible and opening the conversation acknowledges it immediately. Longer
  unread runs remain unread until the reader reaches that exact newest-message
  boundary. Eligibility uses message geometry rather than message count,
  footer/composer space, or a fuzzy near-bottom threshold.
- An unread channel whose acknowledged boundary predates the newest 100
  messages uses the ordinary single newest-page `GET
  /channels/{channel_id}/messages?limit=100`. The viewport starts at the oldest
  row in that page and the banner reports the loaded lower bound (`100+`).
  SakuraCord does not automatically walk backward to find an arbitrarily old
  acknowledgement boundary. An upward user scroll may request one older
  50-message page with `before={oldest_loaded_message_id}&limit=50`; after that
  page is incorporated, the banner grows with the discovered unread rows
  (`150+`, `200+`, and so on). Each additional page requires further user
  scrolling. The conversation cannot acknowledge while the unread boundary is
  unresolved. Once the page containing the acknowledged boundary is loaded,
  the count becomes exact, the true unread divider is shown, and ordinary
  newest-message viewport eligibility applies.
- Forum selection is the deliberate exception to ordinary timeline
  acknowledgement. Once the active forum catalogue is available, a forum with
  unseen thread IDs sends one immediate parent `POST
  /channels/{forum_id}/messages/{current_time_snowflake}/ack`, matching the
  official client's `ACK_FORUM_ACTIVE_THREADS` path. The selection first
  snapshots the preceding parent acknowledgement so posts created after that
  boundary retain their `NEW` badge for the visit. The parent mutation clears
  the channel's `N New` state but never changes a child thread's independent
  unread-reply boundary. The mutation has one attempt and is not repeated by
  warm rerenders or pagination.
- Once that read boundary is established, a read acknowledgement sends one
  immediate `POST /channels/{channel_id}/messages/{message_id}/ack`. This
  deliberately removes Paicord's 1.5-second view debounce: exact native
  geometry prevents a transient pre-position viewport from qualifying, while
  the debounce only delayed an already-qualified user-visible read. The JSON
  body includes the calculated guild/thread read-state `flags` and
  `last_viewed` day relative to Discord's epoch, plus the latest server-issued
  `token` when present. Requests are serialized across the account, coalesced
  per channel, and have one attempt. A `429`, timeout, challenge, restriction,
  or ambiguous failure is not retried automatically. Each optimistic mutation
  records its own preceding boundary and counters; a definite failure reverts
  only that mutation, while an earlier accepted acknowledgement remains the
  rollback floor for a later mutation.
- Marking a message and everything after it unread moves the boundary to the
  preceding snowflake through the same route with `manual: true`, the
  recalculated `mention_count`, and the latest acknowledgement `token` when
  Discord supplied one. A remote `MESSAGE_ACK` carrying `manual: true` may
  therefore move the boundary backward; ordinary acknowledgements remain
  monotonic. Ready read state and `MESSAGE_ACK` versions are retained and
  compared before merging, and an older version is ignored. Equal or newer
  ordinary state still cannot regress the effective boundary. A reconnecting
  Ready snapshot or transient connection state cannot cancel or erase queued,
  in-flight, or accepted optimistic intent; only a definite request failure or
  an account reset can remove it. A matching server event confirms the pending
  intent, while a stale snapshot is overlaid by it. The acknowledgement token
  follows the same account-scoped lifecycle and is not discarded by a Ready
  refresh.
- Discord's accepted acknowledgement and the later versioned Ready read state
  are the durable source across app launches. SakuraCord does not maintain a
  second locally persisted read boundary. A fresh launch rebuilds the same
  effective state from the server snapshot, with later versioned Gateway
  events reconciled through the single account read-state model.
- Message mention decisions use decoded user IDs, role IDs, the
  `mention_everyone` field, current-user guild roles, and authoritative reply
  mention metadata. Message text is never parsed to invent a mention.
- Effective notification policy resolves channel, parent/category, and guild
  settings; guild defaults; active mute expiries; role/everyone suppression;
  Discord's unread-notification flag overrides; and the account-level new
  notifications mode. With new notifications disabled, ordinary guild unread
  defaults to all messages. With it enabled, explicit channel/guild
  `UNREADS_ALL_MESSAGES` and `UNREADS_ONLY_MENTIONS` flags take precedence,
  then ordinary unread follows effective `message_notifications`. Ordinary
  voice-channel traffic and channels carrying
  `IS_GUILD_RESOURCE_CHANNEL` are excluded from guild unread; voice mentions
  remain eligible. Guild channel-opt-in bit 14 excludes ordinary unread from a
  channel or thread unless that conversation or its parent carries opt-in bit
  12. Forum creation notifications additionally honor the parent forum's
  `NEW_FORUM_THREADS_ON` bit 14 and `NEW_FORUM_THREADS_OFF` bit 13. Native
  notifications use the same decision, support foreground presentation and
  exact account/channel/message navigation, and do not add authenticated
  requests.

## Direct-message safety boundary

Opening an existing DM, creating a DM, loading history, and sending are separate
operations. Do not create/open a channel as part of every send. Duplicate sends
must be serialized and deduplicated, and an ambiguous send must never be
repeated automatically.

The production DM contract was rechecked on 29 July 2026 against the public
JavaScript assets shipped by Discord's stable desktop host `0.0.402`, Paicord
revision `694761c1938b73bb60bd58942674dfe73aab1135`, Swiftcord v1 revision
`14465d927ebe1ba34b3befa00f9365fad7b56eb9`, and Discord's public channel and
message documentation. This was a static, unauthenticated comparison; no
account action or traffic capture was performed.

- Existing private channels are restored from `READY.private_channels`; cold
  bootstrap does not issue `GET /users/@me/channels`. Matching Paicord, the
  Ready list is sorted by descending `last_message_id`, falling back to the
  channel snowflake when no last message exists. `CHANNEL_CREATE` appends a new
  private channel, while `MESSAGE_CREATE` updates its `last_message_id` and
  moves it to the front. When Identify requests deduplicated user objects,
  private-channel `recipient_ids` are joined against Ready's top-level `users`
  before any channel reaches presentation; prioritized
  `READY_SUPPLEMENTAL.lazy_private_channels` entries use the same join and
  ordering. This hydration adds no authenticated request; selecting the
  one-to-one DM then uses the established single profile request below.
  `CHANNEL_UPDATE`, `CHANNEL_RECIPIENT_ADD`,
  `CHANNEL_RECIPIENT_REMOVE`, and `CHANNEL_DELETE` reconcile in place without
  inventing another read or mutation. SakuraCord exposes no create-DM,
  user-lookup, group-name, or group-membership REST mutation while those
  product surfaces are disabled.
- History uses one `GET /channels/{channel.id}/messages`, with `before` before
  `limit` when paginating, matching Paicord's reviewed query construction.
  Full profiles use one `GET /users/{user.id}/profile` with
  `with_mutual_guilds`, `with_mutual_friends`, and
  `with_mutual_friends_count` set to `true`; one-to-one DMs omit `guild_id`.
- Message sends remain independent of channel selection. The current
  first-party JSON shape is `mobile_network_type`, `content`, `nonce`, `tts`,
  and `flags`, plus attachments only when present and a reply reference
  containing type `0`, `message_id`, and `channel_id` when needed. The
  `X-Context-Properties` location is `chat_input`. Concurrent calls with the
  same channel and nonce share one in-flight mutation.
- SakuraCord deliberately adds `enforce_nonce: true` to the first-party and
  Paicord bodies. Discord
  publicly documents this as returning the already-created message for a
  duplicate nonce, and SakuraCord's safety contract requires that stronger
  idempotency boundary. This is the sole reviewed body-shape difference.
  Mutations still have one attempt, use server-provided cooldowns, and never
  replay an ambiguous result automatically.
- Swiftcord v1 supplied a historical existing-DM history and send reference. It
  omits a nonce and permits a manual retry after failure, so SakuraCord follows
  the current first-party shape plus the stricter nonce, deduplication, and
  one-attempt safety rules above.

### Private calls

The private-call contract was statically rechecked on 29 July 2026 against
Discord's clean public web build `585344` (version hash
`8b1d591342d4b0a3c7f82d388cbba1dab56b17a9`), the pinned Paicord and Swiftcord
revisions above, and Discord's public Gateway and voice-connection
documentation. No authenticated call was started, answered, declined, or
captured. Paicord exposes opcode 13 and the `CALL_*` event family but its pinned
call handler is incomplete and predates the current `ongoing_rings` field.
Swiftcord v1 and DiscordKit supply only the historical guild-optional voice
state path.

- Private-call discovery is event driven and app wide. `CALL_CREATE` and
  `CALL_UPDATE` carry `channel_id`, `message_id`, region, `ongoing_rings`, and
  an optional guildless voice-state snapshot; `CALL_DELETE` removes or marks
  the call unavailable. `ongoing_rings` maps each ringing recipient to the
  user who initiated that ring. Individual guildless `VOICE_STATE_UPDATE`
  events reconcile participants without conflating calls in other DMs. A
  non-null update first evicts that user from every other private call before
  inserting the destination state, so a direct A-to-B move cannot leave a
  participant behind in A.
- Selecting or joining a private call sends one main-Gateway opcode 13
  `CALL_CONNECT` payload with `channel_id`, deduplicated per channel and
  Gateway session. Media negotiation remains the existing documented voice
  path: main-Gateway opcode 4 with `guild_id: null`, the private channel ID,
  mute/deafen/video state, followed by the matching guildless
  `VOICE_STATE_UPDATE` and `VOICE_SERVER_UPDATE`. The existing DAVE-capable
  voice transport owns the resulting session.
- Starting a one-to-one call performs one ordinary
  `GET /channels/{channel_id}/call` readiness read. The client joins through
  opcode 4, waits for pushed `CALL_CREATE`, and sends at most one
  `POST /channels/{channel_id}/call/ring` with `{"recipients": null}` only when
  the readiness response is ringable. A group-DM start skips the readiness GET
  and otherwise uses the same single ring mutation. A false one-to-one
  `ringable` value still permits a non-ringing joined call.
- Joining an existing or incoming DM/group-DM call sends no readiness read and
  no ring mutation. It subscribes with opcode 13 and joins with opcode 4.
  Accepting an incoming call is the same join path. Declining sends exactly one
  `POST /channels/{channel_id}/call/stop-ringing` with the current user in the
  `recipients` array and does not join.
- Both private-call POSTs use the shared authenticated scheduler and have one
  attempt. They are never replayed after `429`, timeout, challenge,
  restriction, or an ambiguous result. Ringing waits only for pushed call
  creation; it does not poll or probe. An already successful media join is not
  repeated when the later ring mutation fails.
- Type-3 call messages decode their participant list and `ended_timestamp`;
  presentation derives a bounded human-readable duration locally and adds no
  request.

Before materially changing DM creation or sending, recheck the current official
web-client bundle, a clean official client, Paicord, Swiftcord v1, request body,
nonce, context, ordering, challenge behavior, and Gateway reconciliation. Keep
incomplete paths capability-gated until request-contract and request-budget
tests pass.

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

1. compare current public Discord documentation, the current official
   production web-client bundle, pinned Paicord, pinned Swiftcord v1, and a
   clean official client when static evidence is materially ambiguous;
2. record route, headers, body, sequencing, request count, response/error
   behavior, rate limits, retries, cache effects, and reconciliation;
3. state reference revisions/builds and observation dates;
4. record narrow evidence on the roadmap item, pull request, or commit; and
5. update this file only when the new evidence changes a durable
   repository-wide baseline.
