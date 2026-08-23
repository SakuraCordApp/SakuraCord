# Discord production protocol baseline

Last repository audit: 22 August 2026, in a working tree based on SakuraCord
commit `924e52e2`.

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

Message search was re-audited on 14 August 2026 with sanitized CDP capture in a
fresh, cache-disabled, authenticated, renamed official Discord desktop `0.0.407`.
The audit covered server and direct-message searches, current-DM and all-DM
scope, content and filter-only queries, every exposed filter family, combined
and repeated filters, newest/oldest/relevance sorts, zero results, result
navigation, and pagination through the client maximum. No authorization value,
message content, user/channel/guild identifier, or personal response payload was
retained.

Reply-author mention control was statically rechecked on 15 August 2026 against
the official desktop `0.0.407` asset `web.206b719a7d513cf1.js`, the pinned
Paicord and Swiftcord v1 revisions above, and Discord's public allowed-mentions
documentation. The first-party send helper omits `allowed_mentions` while the
reply-author notification is enabled. When it is disabled, the helper sends
`allowed_mentions` with `parse:["users","roles","everyone"]` and
`replied_user:false`, preserving ordinary content-mention parsing. Swiftcord
v1 corroborates that complete disabled shape; Paicord sends the narrower
`replied_user:false` form.

REST transport recovery was audited on 15 August 2026 from a sanitized
authenticated SakuraCord diagnostic captured during a live stall. The main
Gateway continued sending QoS heartbeats and receiving ACKs, while one
acknowledgement and otherwise independent channel-history, profile, and
message-search requests all received no HTTP response and failed at their
configured 30-second timeout. This isolates the failure to the reused REST
connection pool, not account, Gateway, channel, or search state. Production now
keeps REST and Gateway in separate provider-owned URL sessions. The first
confirmed REST timeout replaces only the REST transport generation and cancels
its remaining tasks. A safe read may use its existing two-attempt budget on the
replacement; an authenticated mutation is never replayed because its timeout
is ambiguous. Concurrent reads cancelled by that generation replacement may
likewise consume their one remaining attempt. Deterministic transport tests
cover timed-out GET, read-only DM-search POST, generation coalescing, and
non-replayed mutation behavior. No new Discord route, header, body, or account
action was introduced for this recovery audit.

Go Live was re-audited on 20 August 2026 against a clean, authenticated,
renamed official Discord desktop `0.0.408` (Electron `42.7.1`, Chromium
`148.0.7778.280`) using an isolated profile and CDP. The current main asset was
`web.e7ec05b4366c76c6.js`, SHA-256
`90bc5211ada76376a0a0131668e57f2889e5cfc7be9f52c8fd4a63d031ed35e0`.
The inspection retained no credential, cookie, authorization value, personal
identifier, media frame, or unsanitized payload. DiscordKit commit
`32b2e3130f5da93f4c95646e7fbbe1abe5045960` independently corroborated the
main-Gateway opcodes, event fields, stream-key grammar, and preview route, but
contains no capture or RTC media implementation. Pinned Paicord contains the
opcode constants and voice-state flag but leaves stream dispatch incomplete;
pinned Swiftcord v1 contains no matching Go Live implementation. Those sources
were cross-checks, not media code to copy.

Three controlled entire-screen broadcasts were also started and stopped in
that authenticated client in the `Testing Server 2` voice channel while the
main page and worker targets were monitored through CDP. Each observed start
sent opcode 18 with `type:guild`, guild/channel IDs, and
`preferred_region:"warsaw"`, followed by opcode 22 with the allocated key and
`paused:false`; each stop sent opcode 19 with only that key. No `/streams/`
HTTP request was made during any observed start or stop. The REST preview route
below is therefore a separately verified on-demand read, not part of broadcast
allocation or teardown.
Authenticated interoperability in the same server additionally confirmed that
SakuraCord can decode/watch an official-client broadcast and that an official
client can watch SakuraCord's broadcast.

Private DM and group-DM calls were re-audited on 22 August 2026 against a
fresh, signed, notarized, renamed official Discord desktop `0.0.408`
(Electron `42.7.1`, Chromium `148.0.7778.280`, client build `595897`, native
build `88466`) in an isolated profile. CDP was attached before each scenario.
The two test accounts alternated broadcaster/viewer roles between the official
client and SakuraCord. The sanitized capture covered call start, join, leave,
last-participant end, broadcast start/stop, initial watch behavior, explicit
watch/leave/rejoin, stream termination while watched, source-selection failure,
main Gateway, REST, call Voice, stream Voice, DAVE negotiation, and cleanup.
No credential, cookie, authorization value, personal identifier, IP address,
media frame, or unsanitized payload was retained. The temporary automation and
capture paths and all capture files were removed after the durable evidence
below was recorded.

Server search uses `GET /guilds/{guild}/messages/search`; it does not use the
older selected-channel route. The ordered query contains optional repeated
`author_id`, `channel_id`, `mentions`, `has`, and `author_type` items, optional
`pinned`, `min_id`, `max_id`, and trimmed `content`, followed by `sort_by`,
`sort_order`, and `offset`. There is no `limit` query item; Discord returns 25
nested result groups per page. The observed values are `has` = `image`, `video`,
`link`, `file`, `embed`, `sound`, `poll`, `sticker`, or `forward`, and
`author_type` = `user`, `bot`, or `webhook`. Timestamp sorts use
`sort_by=timestamp` with `desc` for newest and `asc` for oldest; relevance uses
`sort_by=relevance&sort_order=desc`. Pages use offsets 0, 25, …, 9,975, and the
client exposes at most 400 pages.

All-DM and current-DM search both use
`POST /users/@me/messages/search/tabs`, not a channel message-search endpoint.
The JSON body has `tabs.messages` containing the same sort fields, optional
content/filter arrays or booleans, numeric `offset`, and `limit:25`, plus
top-level `track_exact_total_hits:true`. Current-DM scope is expressed only as a
top-level `channel_ids` array; omitting it searches every DM. DM pagination still
advances `offset` by 25 even though the response also supplies a cursor.

Both response families carry nested message groups; the message whose `hit`
field is true is the result while siblings provide rendering context. Guild
responses expose `total_results`, `doing_deep_historical_index`, and optional
thread/member data. DM responses place `messages`, `channels`, `total_results`,
`time_spent_ms`, and `cursor` under `tabs.messages`. A `202` is an indexing
response with an original request plus at most five server-delayed retries.
Typing does not issue requests: only Return, a sort/filter application, or an
explicit page selection submits search. Selecting a result keeps the side panel
open, navigates to its actual channel or DM, and focuses the exact message.

For calendar filters, the desktop translates `before:DATE` to the snowflake at
local midnight starting that date (`max_id`), and `after:DATE` to local midnight
starting the following date (`min_id`), making the selected calendar day
exclusive in each direction. Pinned Paicord revision
`694761c1938b73bb60bd58942674dfe73aab1135` and Swiftcord v1 revision
`14465d927ebe1ba34b3befa00f9365fad7b56eb9` still have no corresponding
message-search implementation.

The GIF-picker surface was re-audited on 6 August 2026 against clean, signed,
notarized Discord desktop `0.0.406` and production asset
`web.b96889ed56c413ab.js` (SHA-256
`1990d86f35f4e4071ff499fcd0f18c04b44a27fdbfafd61b80011c67c10b1654`).
The clean host used the existing authenticated Discord profile while the
installed modified Discord/Equicord bundle remained untouched. Sanitized CDP
observation covered opening the picker, opening trending and favourites,
searching for `hello`, and one add-then-remove favourite restoration. No GIF
was sent and no content, credential, cookie, or authorization value was
retained. Paicord has a placeholder picker and the matching generated
favourites protobuf schema but no GIF HTTP implementation. Swiftcord v1 has no
corresponding GIF picker, search, or favourites path.

The native GIF media follow-up was rechecked on 7 August 2026 against that same
first-party asset (the fetched asset still matched the recorded SHA-256). Its
picker result normalizer consumes the response-provided `src` and `gif_src`
media URLs; the selected format for these routes is WebM. A sanitized current
SakuraCord response confirmed that Discord search and landing results now use
`static.klipy.com` WebM and WebP media. The first-party picker assigns those
response URLs directly to its image and video elements without applying
Discord's separate `isAllowedGifProviderUrl` asset-action helper. Discord's current
public developer-documentation index, API reference, and message resource do
not document the normal-user GIF-picker routes or its media providers.
Klipy's current [API documentation](https://docs.klipy.com/getting-started)
and Google's current [Tenor response documentation](https://developers.google.com/tenor/guides/response-objects-and-errors)
confirm that media responses contain separate format-specific URLs. The pinned Paicord
revision still has only its placeholder picker and generated favourites
schema, with no GIF media fetch. The pinned Swiftcord v1 and DiscordKit
revisions still have no GIF picker or media path. Those absences provide no
alternative origin, header, retry, or fallback behavior to copy.

The native sign-in preflight was re-audited on 7 August 2026 against production
asset `web.3cd0f98a15f63be2.js` (SHA-256
`a77974b18a92b7d5452d4138b0b276f380ac498fd7fefa1b9aa7e183ace0f4f0`).
The first-party Apex action requests the integer `APP` surface, accepts an
optional returned installation, and records a fetch failure without blocking
the independent authentication-store `/experiments` request. That request
accepts both `fingerprint` and `installation`. Sanitized unauthenticated checks
confirmed that `surface=2` and an installation-free
`with_guild_experiments=true` request each returned a nonempty server-issued
installation; the latter also returned a nonempty fingerprint. Public Discord
documentation has no corresponding normal-user authentication endpoints.
Pinned Paicord performs only its fingerprint `/experiments` request and has no
Apex path. Pinned Swiftcord v1 delegates sign-in to Discord's embedded web
flow. No credential, authenticated login, or personal response value was used
or retained for this re-audit.

The post-approval installation repair was re-audited on 8 August 2026 after two
sanitized SakuraCord QR-login traces showed successful Apex responses that
contained assignments but no installation; the second trace also showed the
fallback `/experiments` response returning a fingerprint and assignments but no
installation. The current production asset
`web.6d63a33a2f3badf3.js` (SHA-256
`da550764957c0a3974bf3ac5fd72816075aa13c67b9443f784471bd6158ce6b9`)
still treats both response installations as optional and conditionally adds
`installation_id` to Gateway Identify only when one is available. Discord's
public Gateway documentation requires only `os`, `browser`, and `device` as
connection properties and has no corresponding normal-user authentication
routes. Pinned Paicord performs only its installation-free fingerprint
`/experiments` request and its Gateway Identify has no installation field;
pinned Swiftcord v1 delegates sign-in to Discord's embedded web flow and starts
Gateway without managing an installation. The repair therefore makes the two
lookups best-effort and proceeds without the optional field when both omit it;
it retains a returned installation when present and never replays authentication.
No credential, challenge solution, or personal response value was retained.

Message forwarding and its destination picker were re-audited on 9 August
2026 against clean, renamed Discord desktop `0.0.406` (Electron `42.7.1`,
Chromium `148`) and production asset `web.6d63a33a2f3badf3.js` (SHA-256
`da550764957c0a3974bf3ac5fd72816075aa13c67b9443f784471bd6158ce6b9`). The
first-party action sends one ordinary message mutation per selected destination
with empty wrapper content, a nonce but no `enforce_nonce`, `tts:false`,
`flags:0`, `message_reference.type = 1`, source message/channel/guild IDs, and
`X-Context-Properties` location `forwarding`. Multiple destination mutations
start together and are settled independently. If the user also enters context,
the client sends it as one subsequent ordinary message per destination only
after that destination's forward succeeds; it omits the context send when
slowmode applies and the user lacks the bypass permission. A missing direct
message is resolved first with one coalesced `POST /users/@me/channels` carrying
the single recipient. The picker caps explicit selection at five.

The source eligibility guard accepts only message types `0`, `19`, `20`, `23`,
and `35`. It rejects failed local sends, polls, shared client themes, activities,
calls, activity instances, forwarding-disabled sources, gated channels or
threads, sources without read-message-history permission, and any flag outside
the first-party allowlist (`1`, `2`, `4`, `16`, `32`, `256`, `512`, `1024`,
`4096`, `8192`, `16384`, `32768`, and `524288`). Destination validation also
checks send permission plus attachment, embed-link, external-sticker, and voice-
message permissions required by the immutable snapshot.

Sanitized CDP captures showed that opening, scrolling, and typing in the picker
perform no destination REST request or Gateway search; search is local over the
account-wide channel store, active joined threads, known users, and direct
messages. `READY_SUPPLEMENTAL.users` extends that known-user set without a REST
lookup, and relationship nicknames plus legacy discriminators remain available
to the user-search worker. Discord's joined-thread store is distinct from its
forum catalogue: `CONNECTION_OPEN` admits active thread records only when their
embedded `member` is present, while thread-list and member events update or
remove that membership without a forum-page replacement erasing it. Blank
results concatenate picker-local destinations
selected from a typed search, the remove-and-unshift channel history capped at
eight and persisted by the client-local `QuickSwitcherStore`, and computed
frequent destinations. A client relaunch therefore preserves this history;
each `CHANNEL_SELECT` removes the selected channel if already present, prepends
it, and truncates the stored list to eight. The three sources then
deduplicate, omit the source
unless search-selected, and cap the final list at 15. Selecting a destination
already visible in the blank list does not move it or create a picker-local
pin. Selecting a typed-search result clears the query and prepends that result,
followed by the picker's other currently selected destinations in their
existing selection order, for the lifetime of the open picker; the searched
result remains pinned even if it is later deselected.

Typed search separately caps raw user, group-DM, text/thread, and voice
categories at 20 before the Forward-specific destination filter runs and then
combines the survivors by the first-party match and frecency score. A sanitized
10 August follow-up inspected the live query helpers and confirmed that denied
voice rows can consume raw category slots without lower eligible matches being
backfilled; forum and media rows behave equivalently in the raw text category.
The account-wide user index is updated from Ready, Ready Supplemental,
`GUILD_CREATE`, batched member chunks, individual member changes, relationship
and private-channel changes, forum/thread loads, and authors and mentions in
successful message-history or live-message events; these are cache updates and
add no picker request. The manager does not subscribe to
`GUILD_MEMBER_LIST_UPDATE`, so ordinary virtualized member-list range updates
must not add Forward user candidates. The
10 August follow-up also inspected production asset
`web.2548ec5eac0614b5.js` (SHA-256
`514e91b189b59604adb5d008008b20f9c0f72aec9deb7915989c5f6da5506216`)
and its user-search worker `16844172e1c61d95.js` (SHA-256
`42090c7222926792067af81023aefe1ec5fd1e26c1a2b2276f34513e4bc59fcd`).
Its user and guild-member stores process `LOCAL_MESSAGES_LOADED` before
`CONNECTION_OPEN`, so identities and guild nicknames recovered from local
message pages seed insertion order before Ready users and members; subsequent
history and live-message discoveries append without moving existing entries.
SakuraCord mirrors that state source with an account-scoped cache containing
only message-observed user identity records and nonempty guild nicknames from
the current resolved member store. Ephemeral guild, member-chunk, relationship,
and private-channel updates feed the live index without being written into the
message-derived cache. Like Discord's GuildMemberStore, it does not
index the historical `message.member` nickname embedded in a message. It
does not retain message bodies for Forward search, and loading or updating this
cache performs no Discord request. The
global channel query requires each vocal destination's full first-party
`accessPermissions`, including `VIEW_CHANNEL` and `CONNECT`; non-vocal guild
destinations require `VIEW_CHANNEL` at this raw-search stage. The later Forward
filter rejects forum/media destinations and requires `VIEW_CHANNEL` plus
`SEND_MESSAGES` for guild text, thread, and voice survivors. The
matcher assigns exact, prefix, containment, all-term, then ordered-subsequence
scores for channel and Group-DM records. User results come from Discord's
account-wide user-search worker. Its identity order is username, relationship
nickname, global name, then guild nicknames in store order; prefix, containment,
and ordered-subsequence matches score `10`, `5`, and `1`. The subsequence check
runs over both accent-folded text and the worker's Unicode-confusable skeleton.
The current skeleton uses compatibility-equivalent styled letters and includes
the ASCII transformations `0 → o`, `1/I → l`, and `m → rn`. The first identity
with the highest score becomes the comparator. The picker uses the first-party
unified comparator: it sorts by score, then sorts equal-score user rows by that
lowercased comparator using JavaScript UTF-16 code-unit order. Channel and
Group-DM results provide `sortable`; the current first-party comparator reads
the left result's `sortable` for both operands, so those equal-score rows
preserve the candidate store's order. The global channel candidate order is
the `ChannelStore` insertion sequence: `CONNECTION_OPEN` visits guild records
in their Gateway order and inserts each full-sync channel item in payload
order; `loadAllGuildAndPrivateChannelsFromDisk()` then exposes guild channels
in that raw order before private channels. This is intentionally independent
of the category/position ordering used by the channel sidebar. SakuraCord
therefore retains a separate raw channel-ID sequence for Forward search rather
than reusing its presentation-sorted channel array. The
separate category/channel-position comparator in the same bundle belongs to
application-command channel arguments and is not used by the Forward picker.
The final merge preserves category concatenation order when scores tie. Named Group DMs show recipient display
names as detail, while an unnamed Group DM with an empty raw name has no detail.
The guild/channel frecency store retains at most ten samples, overrides the
generic engine's weight function with `0/1/2–3/4–6/>=7` day weights of
`100/70/50/30/10`, and computes
`ceil(totalUses * recencyWeight / samples)`;
persisted computed score fields are discarded and entries without a retained
sample are omitted. The channel matcher adds up to three points before its
match-class cap using the live Forward path's `100`-point bonus scale; the category
booster separately multiplies by `1 + score / maximumResolvedScore`. Like the
first-party persisted store, locally pending channel and guild selections
survive a relaunch; SakuraCord stores an account-scoped aggregate containing
the pending total-use delta and newest ten timestamps, then replays it over the
fresh settings snapshot without an extra request. Controlled
fresh-launch comparisons reproduced the same
navigation sequence before comparing blank search, multiple queries, and deep
scroll results. Live forwarding used a controlled test message; only sanitized
request shape and counts were retained, never credentials, authorization
metadata, message content, or personal identifiers.

Pinned Paicord has snapshot decoding/rendering and a placeholder Forward action,
but no forwarding request or destination-picker implementation. Pinned
Swiftcord v1 has neither forwarding nor snapshot support. DiscordKit at the
repository pin has no forwarding implementation; its later `73c0996` DTO-only
addition remains a decoding cross-check rather than picker, request, or ordering
evidence.

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
| GIF picker, search, favourites, and sending | Enabled | Enabled with fixtures |
| Message forwarding and forwarded snapshot rendering | Enabled | Enabled with fixtures |
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
  remote-auth Gateway envelopes;
- a provider-owned REST connection pool distinct from the Gateway pool, with a
  generation-coalesced replacement after a confirmed 30-second transport
  timeout; and
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

The current first-party web asset defines the Apex experiment surface
`APP` as integer `2` and sends that value on the current login path. A sanitized
unauthenticated production check returned `400` / Discord error `50035` for the
obsolete string `discord_app`, while `surface=2` returned `200` with the
expected installation field. The first-party action does not make that fetch a
prerequisite for its independent `/experiments` path, which also accepts a
returned installation. Discord's public API documentation, pinned Paicord, and
pinned Swiftcord v1 have no corresponding Apex implementation.

### Audited HTTP route surface

This is the complete production Discord HTTP surface reachable from the
current app. Optional keys are omitted from JSON rather than encoded as null
unless the row says otherwise. `P−` and `S−` mean the pinned Paicord or
Swiftcord v1 revision has no corresponding implementation; absence was checked
and retained as evidence.

| Method and route template | Trigger and exact supported request shape | Cross-reference result |
| --- | --- | --- |
| `GET /apex/experiments?surface=2` | Primary cold native password/MFA installation preflight, or the first best-effort request in a pending-QR/stored-session repair when the credential lacks its installation identity; unauthenticated, no body, Authorization, fingerprint, installation header, or heartbeat session. Only a returned installation ID is retained. If the request fails or omits it, `/experiments` follows. The obsolete string surface is rejected with `400` / `50035`. | Current official login treats Apex failure and an omitted installation as non-blocking before its independent authentication-store preflight; P−, S−. |
| `GET /experiments?with_guild_experiments=true` | Cold native password/MFA fingerprint preflight, or one pending-QR/stored-session installation fallback after Apex fails or omits the identity; unauthenticated, no body, and `X-Context-Properties` location `Login`. It carries the Apex-issued installation when available. Password login requires only the returned fingerprint; all paths retain a nonempty installation when present and otherwise omit it from REST and Gateway metadata. | Current official login accepts both response fields independently and conditionally adds installation to Gateway Identify; Paicord supplies the installation-free fingerprint and Gateway cross-check; Swiftcord v1 has no native-login counterpart and starts Gateway without managing installation. Paicord lacks the current query/context shape. |
| `POST /auth/login` | Explicit login; `login`, `password`, `undelete:false`, `login_source:null`, and `gift_code_sku_id:null`; one user-completed CAPTCHA replay may add challenge headers. | Current official live password login and web action; Paicord omits the null keys; S−. |
| `POST /auth/mfa/{totp,sms,backup}` | Explicit MFA; `code`, `ticket`, optional `login_instance_id`, `login_source:null`, and `gift_code_sku_id:null`. | Current official web action and Paicord; no live MFA challenge occurred in the 3 August clean-client pass; S−. |
| `POST /auth/mfa/sms/send` | Explicit SMS choice; `ticket`. | Current official and Paicord; S−. |
| `POST /users/@me/remote-auth/login` | Approved QR ticket exchange; `ticket`; at most one user-completed CAPTCHA replay. | Current official remote-auth v2 and Paicord; S−. |
| `GET /users/@me` | Incomplete-Ready compatibility fallback for a previously stored session only; no body. A newly authenticated session fails closed if Ready omits its user and never sends this route. | Public user semantics and Paicord. Current official login and Swiftcord v1 obtain the authenticated user from Gateway Ready; Paicord login performs this extra read. |
| `GET /users/@me/guilds` | Incomplete-Ready compatibility fallback only; no body. | Public guild semantics; normal current official/Paicord/Swiftcord startup uses Gateway instead. |
| `GET /guilds/{guild}/channels` | Cache-miss fallback only; no body, coalesced by guild. | Public channel semantics and all three client references. |
| `GET /guilds/{guild}/roles` | Visible role/member UI cache miss; no body, coalesced. | Public guild semantics and all three client references. |
| `GET /guilds/{guild}/roles/{role}/member-ids` | Explicit role inspection; no body; result display capped at 1,000. | Current first-party route; P−, S−. |
| `GET /users/{user}/profile` | Explicit profile; `with_mutual_guilds=true`, `with_mutual_friends=true`, `with_mutual_friends_count=true`, plus `guild_id` only in guild context; coalesced by user and guild context. A `404` for an unavailable user remains scoped to the profile presentation and does not stop the session. | Current first-party and Paicord; Swiftcord has historical profile data but no equivalent complete route. |
| `GET /collectibles-products/{product}` | At most one cache-miss read for a profile effect returned by the profile response; query contains the current `locale`. | Current first-party route; P−, S−. The obsolete `/user-profile-effects` fallback was removed. |
| `GET /guilds/{guild}/emojis` | Stale/missing Gateway and disk-cache fallback; no body, coalesced. | Public emoji semantics and all three client references. |
| `GET /users/@me/settings-proto/2` | Explicit emoji- or GIF-favourites-settings cache miss; no body, coalesced for the provider session. | Current first-party and Paicord's generated Frecency settings schema; Swiftcord has the versioned settings-proto path but no GIF picker. |
| `PATCH /users/@me/settings-proto/2` | One explicit GIF favourite add or remove; JSON contains only `settings`, whose value is the complete updated base64 Frecency proto. The favourite map key is the canonical GIF URL. Its value contains format (`IMAGE = 1`, `VIDEO = 2`), source URL, width, height, and monotonically increasing order; display order is descending order. The declared format is preserved on reads, including for extensionless CDN sources. Unrelated and unknown top-level proto fields are preserved. | Current first-party action and generated Paicord schema; Swiftcord v1 has no GIF favourite mutation. |
| `GET /gifs/trending?locale={locale}&media_format=webm` | Opening the GIF picker; one cacheable landing read returning the current base categories in server order and their preview media. | Current first-party route and clean-client request; P−, S−. |
| `GET /gifs/trending-gifs?media_format=webm&locale={locale}` | Explicit Trending GIFs selection; no body. The returned order is preserved. | Current first-party route and clean-client request; P−, S−. |
| `GET /gifs/search?q={query}&media_format=webm&locale={locale}` | Nonempty picker search after the current 250 ms debounce; no speculative or paginated follow-up. The live default response is 50 results and its order is preserved. | Current first-party route/action and clean-client `hello` request; P−, S−. |
| `GET /channels/{channel}/messages` | Visible history only; guild history requires effective `VIEW_CHANNEL` and `READ_MESSAGE_HISTORY`, and voice-channel history additionally requires `CONNECT`. The current clean client uses `limit=10` for a newly selected uncached channel, which SakuraCord matches once per channel per uninterrupted Gateway connection. A dispatched newest-page read is allowed to finish and populate the session stores after a later selection supersedes its presentation; rapid navigation does not abort those reads. Reopening a loaded newest-backed channel restores its bounded session-memory page and sends no history request. After a Gateway gap, the retained page is presented immediately but its completeness marker is invalidated; returning to Ready refreshes the selected page once and later reopened pages refresh once on selection. Distant navigation uses `around={message}&limit=50` as a replacement window; its older and newer edges paginate independently with `before={oldest}&limit=20` and `after={newest}&limit=20`. A historical window is not cached as though it were newest-backed. No body. | Public message semantics and `before`/`after`/`around` pagination, current first-party permission/message paths and stale-connection refresh, and Paicord's permission-checked channel store. Swiftcord v1 checks `VIEW_CHANNEL` before presentation but otherwise supplies only a historical unguarded/refetching history path. Paicord retains a per-channel in-memory store and uses a historical 50-message initial page. The current first-party cache behavior and connection-generation invalidation take precedence. |
| `GET /guilds/{guild}/messages/search` | One explicit server search on Return, filter/sort application, or page selection. Optional repeated `author_id`, `channel_id`, `mentions`, `has`, and `author_type`; optional `pinned`, date snowflakes, and trimmed `content`; then exact sort and 25-step offset fields. No `limit` query item. Nested groups select their `hit` message and retain context for shared timeline rendering and exact-result navigation. | Sanitized authenticated clean-client CDP matrix on 14 August 2026; P−, S−. |
| `POST /users/@me/messages/search/tabs` | One explicit DM search with `tabs.messages`, `limit:25`, 25-step `offset`, exact sort/filter fields, and `track_exact_total_hits:true`. Optional top-level `channel_ids` scopes the same endpoint to one or more DMs; omitting it searches all DMs. Returned channel metadata is merged before exact-result navigation. | Sanitized authenticated clean-client CDP matrix on 14 August 2026; P−, S−. |
| `GET /channels/{thread}` | One unknown-thread deep-link resolution; no body. | Public channel semantics and all three references. |
| `POST /channels/{forum}/threads?use_nested_fields=true` | Explicit forum creation; `name`, `auto_archive_duration`, ordered `applied_tags`, nested `message` with `content`, `sticker_ids:[]`, and attachments only when uploaded. | Current first-party action; Paicord and Swiftcord have only partial/historical thread creation. |
| `GET /channels/{forum}/threads/search` | Forum catalogue: `archived=true`, `sort_by`, `sort_order=desc`, `limit`, `offset`, and optional `tag`/`tag_setting`; name search adds `name`. | Current first-party route; P−, S−. |
| `POST /channels/{forum}/post-data` | Preview hydration with `thread_ids` batches of at most ten. | Current first-party route; P−, S−. |
| `PATCH` or `DELETE /channels/{thread}` | One explicit forum metadata mutation or deletion; partial body for the selected action only. | Current first-party and public channel semantics; partial Paicord/Swiftcord coverage. |
| `POST /channels/{thread}/thread-members/@me?location=Change%20Notification%20Settings` | One join only when changing settings for an unjoined post; empty body. | Current first-party route; P−, S−. |
| `PATCH /channels/{thread}/thread-members/@me/settings` | Explicit thread notification change; only reviewed `flags`, `muted`, and `mute_config` keys. | Current first-party route; P−, S−. |
| `POST /channels/{channel}/typing` | Empty body after the local 1.5-second delay and eight-second coalescing window. | Public typing semantics and all three references. |
| `POST /channels/{channel}/messages/{message}/ack` | One viewport-qualified acknowledgement; `token` is always present (null before Discord issues one), `last_viewed` is the current Discord-epoch day, and `flags` is sent only when the recomputed guild/thread value differs from Ready state. Manual-unread fields remain explicit-action-only. | Current first-party and Paicord; S−. |
| `POST /read-states/ack-bulk` | Explicit “Mark Server as Read”; at most 100 unread channel/thread entries per sequential request, each containing `channel_id`, `message_id`, and channel `read_state_type:0`. | Current first-party; P−, S−. |
| `PATCH /users/@me/guilds/{guild-or-@me}/settings` | One explicit channel notification change; a single partial `channel_overrides` entry. | Current first-party; P− and S− for the private `@me` scope. |
| `PATCH /users/@me/guilds/settings` | One explicit server or category notification change; `guilds` contains exactly one partial guild entry. Category changes contain one category-keyed `channel_overrides` entry and only the selected notification, mute, or collapse fields. | Current first-party; P−, S−. |
| `GET /guilds/{guild}/application-command-index`, `/channels/{channel}/application-command-index`, `/users/@me/application-command-index`, or `/applications/{application}/application-command-index` | Target-specific index; at most three created GETs for the reviewed `202`/`429` readiness flow. | Current first-party route family; P−, S−. |
| `POST /interactions` | One explicit type-2 execution, type-4 autocomplete, or returned modal submission; nonce-keyed, one attempt. | Current first-party and Paicord command model; Swiftcord has no current index/interaction path. |
| `POST /channels/{channel}/messages` | One explicit send; `content`, nonce, `tts:false`, `flags:0`, macOS `mobile_network_type:"unknown"`, optional reply/attachments, and `X-Context-Properties` location `chat_input`. A reply with its author notification enabled omits `allowed_mentions`; disabling it adds `parse:["users","roles","everyone"]` and `replied_user:false`. SakuraCord deliberately adds `enforce_nonce:true` to ordinary composer sends. An explicit forward uses the same route once per selected destination (maximum five), empty `content`, nonce without `enforce_nonce`, `message_reference` with `type:1` and source IDs, and context location `forwarding`. Selected forwards start together and settle independently. Optional user-entered context is one later ordinary send per successful destination unless slowmode without bypass forbids it. Picker browsing and typing perform no HTTP or Gateway search. | Current first-party build and clean macOS CDP request/search observation. Pinned Paicord has no forward request/picker; its ordinary reply path has the narrower disabled-mention shape. Swiftcord v1 corroborates the complete reply mention control but has no forward path. DiscordKit's later DTO-only snapshot support is decoding evidence, not request or picker evidence. |
| `POST /channels/{channel}/attachments` | Explicit files only; `files` entries contain string index `id`, `filename`, `file_size`, and `is_clip:false`. | Current first-party upload action and Paicord; Swiftcord has no comparable presigned upload. |
| `PUT {Discord-issued upload_url}` | One unauthenticated storage PUT per reserved file, `application/octet-stream`, raw bytes, no Discord authorization metadata. | Current first-party and Paicord; S−. |
| `PATCH` or `DELETE /channels/{channel}/messages/{message}` | Explicit edit with only `content`, or explicit deletion with no body. | Public message semantics and all three references. |
| `PUT` or `DELETE /channels/{channel}/messages/{message}/reactions/{emoji}/@me` | One coalesced explicit reaction intent; empty body. | Public reaction semantics and all three references. |
| `GET /channels/{channel}/messages/{message}/reactions/{emoji}` | Visible reactor preview only; `type=0&limit=5`, no pagination. | Public reaction-user semantics and current first-party; Paicord/Swiftcord provide historical reaction reads. |
| `GET /channels/{dm}/call` | One-to-one explicit call start readiness read only; no body. | Current first-party; P−, S− for the current readiness contract. |
| `POST /channels/{dm}/call/ring` | Explicit call start after pushed call creation; `recipients:null` or the explicit recipient list. | Current first-party; Paicord partial, S−. |
| `POST /channels/{dm}/call/stop-ringing` | Explicit decline; nonempty `recipients` list. | Current first-party; Paicord partial, S−. |

The first-party asset also defines `/gifs/select`, `/gifs/suggest`, and
`/gifs/trending-search`. They are not required for picker content, search,
favourite persistence, or message sending and SakuraCord deliberately does not
issue those analytics/suggestion requests. A picker open creates the landing
read and the shared settings read only. Search and trending each create one
GET, and each favourite action creates one non-retried PATCH.

### Attachment selection and external-host fallback

Before an attachment enters a composer, SakuraCord applies Discord's current
per-file account cap using binary byte counts: 10 MiB for a base account,
50 MiB for Nitro Basic or legacy Nitro Classic, and 500 MiB for Nitro. A file
at the exact boundary is accepted. A larger file is rejected during selection,
before `/channels/{channel}/attachments` can be reserved; the provider repeats
the check as a fail-closed guard.

The 5 August 2026 evidence for this mapping is Discord's public
[account-caps article](https://support.discord.com/hc/en-us/articles/33694251638295-Discord-Account-Caps-Server-Caps-and-More),
the public [user resource](https://docs.discord.com/developers/resources/user)
premium-type values, and current production web asset
`web.d96787f461ff77e9.js` (SHA-256
`216e7f6ce5c61983a33254229f76773984545f0a35402dca7c3376176573215e`).
That asset maps premium types 1 and 3 to `0x3200000`, type 2 to
`524288000`, and the default to `0xa00000`, and rejects only when
`file.size > maximum`. Paicord revision
`694761c1938b73bb60bd58942674dfe73aab1135` independently performs its size
check before staging in `Common/Chat/Input/InputBar.swift` and uses the same
tier values in `Utilities/PaicordLib++/NitroHelper.swift`. Swiftcord v1 revision
`14465d927ebe1ba34b3befa00f9365fad7b56eb9` has a corresponding pre-attach
check in `Swiftcord/Utils/Extensions/MessagesView+.swift`, but its fixed 8 MiB
value is historical and was not adopted. Static first-party and public evidence
left no material request-shape ambiguity, so no authenticated upload was made
for this audit.

An oversized ordinary-message attachment may expose these separate,
user-selected third-party actions:

| Endpoint | Bound and body | Result handling |
| --- | --- | --- |
| `POST https://catbox.moe/user/api.php` | At most 200,000,000 bytes (advertised as 200 MB); anonymous multipart `reqtype=fileupload` and `fileToUpload`. | Accept only an HTTPS `files.catbox.moe` response; the file is permanent. |
| `POST https://litterbox.catbox.moe/resources/internals/api.php` | At most 1,000,000,000 bytes (advertised as 1 GB); anonymous multipart `reqtype=fileupload`, `time=24h`, and `fileToUpload`. | Accept only an HTTPS `litter.catbox.moe` response; the file expires after 24 hours. |

These requests never carry a Discord credential, cookie, message body, or
Discord client metadata. Nothing is uploaded until the user chooses a named
host in the size warning. Success adds the returned URL to the same draft for
review; it never sends a Discord message. Cancellation or failure performs no
Discord mutation. Catbox's documented blocked executable and document
extensions are rejected locally. The implementation was cross-checked against
Equicord's GPL-licensed
[`FileUpload` plugin](https://github.com/Equicord/Equicord/tree/main/src/equicordplugins/fileUpload)
for behavior only and independently implemented against Catbox's official
[tools/API documentation](https://catbox.moe/tools.php),
[service limits](https://catbox.moe/), and [FAQ](https://catbox.moe/faq.php).

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
| Ordinary authenticated read | 2 for GET and the read-only DM-search POST; the second attempt occurs only after a server `429` cooldown or on the replacement REST generation after a confirmed transport stall. |
| Authenticated mutation | 1; no automatic replay after `429`, timeout, or ambiguous failure. A confirmed timeout may replace the REST generation only for later work. |
| Application-command index readiness | 3 created GETs for the separately tested `202`/`429` flow. |
| Message-search index readiness | 6 logical indexing attempts: the original plus at most 5 retries after server `202`, each delayed by the server's `Retry-After` or `retry_after` value (with a five-second fallback only when neither is present). Each logical guild GET or read-only DM POST retains the ordinary two-created-request budget for one server `429` cooldown or one confirmed REST-generation recovery. |
| Cold native installation/fingerprint preflight status retry | Each created preflight request has its original attempt plus at most 3 bounded retries for `429`, `500`, `502`, or `504`, subject to the established delay ceiling. A missing Apex installation creates only the already-required `/experiments` request, without an additional probe. |
| Pending-QR or stored-session missing-installation repair | Once per provider: 1 unauthenticated Apex GET, plus 1 unauthenticated `/experiments` GET only when Apex fails or omits the identity. Both are best-effort; no automatic retry or authentication replay, and Gateway proceeds without the optional identity when unavailable. |
| Native password/MFA status retry | Original plus at most 2 current-official retries for `429`, `500`, `502`, or `504`, subject to the established delay ceiling. |
| Remote-auth ticket status retry | Original plus at most 3 Paicord-policy retries for `429`, `500`, `502`, or `504`, subject to its delay ceiling. |
| User-completed login CAPTCHA | At most 1 replay of the challenged request. |

Any `429` pauses authenticated traffic until the server-provided cooldown.
Route and global bucket data come from response headers/body; SakuraCord does
not hard-code Discord rate limits or probe early. The first request for each
normalized route and Discord major parameter is dispatched immediately. Only
concurrent requests for that same, still-unknown key wait for the discovery
response; different routes and major parameters remain independent. A
successful response without a bucket header marks the key as unbucketed and
releases later requests without an app-owned cadence. Otherwise, the response
associates its bucket identifier with the key, and later requests wait only for
that learned bucket, a route-specific cooldown, or a server-declared global
cooldown.

Mutations preserve their nonce or idempotency fields and rely on REST/Gateway
reconciliation. A definite failed message may expose one explicit user retry
with the original nonce and `enforce_nonce`; an ambiguous timeout remains
waiting for confirmation and cannot be retried automatically.

Authentication failures, account restrictions, verification/challenge
responses, invalid client metadata, malformed mutation responses, and repeated
unexpected not-found responses can open the session-wide safety circuit.
Ordinary resource-scoped permission failures remain scoped when the decoded
Discord error does not indicate an account/session condition. Expected
resource-scoped not-found responses, including an unavailable user profile,
remain scoped to the initiating presentation.

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

The ETF parser reads directly from the decompressed payload's bounded byte
buffer. READY is decoded from that JSON-compatible value tree without first
serializing the tree to JSON and reparsing it. This is an internal allocation
and latency optimization only: the same DTO validation, exact integer rules,
diagnostics projection, event ordering, and malformed-payload failure behavior
remain authoritative.

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
- capped, jittered reconnect backoff that persists until recovery or an explicit
  stop;
- a connection generation that prevents stale tasks from affecting a new
  socket; and
- explicit stop/logout with no reconnect.

The complete outgoing main-Gateway opcode surface is 2 Identify, 3 presence, 4
voice state, 6 Resume, 8 bounded guild-member request/search, 13 private-call
subscription, 37 bulk guild subscription, 40 QoS heartbeat, and 41 time-spent
session update. After an initial idle Ready, the desktop lifecycle order is 4
(null voice state), 3 (current presence), 41, then 40. When a Voice connection
survives a Gateway gap, SakuraCord preserves that active state instead of
publishing the idle reset, then republishes the current channel and local
mute/deafen/video flags after Ready. QoS payloads use version 29 and only
the locally known `foregrounded` reason; heartbeat sessions rotate after 30
minutes inactive and the REST super-properties update with the same session.
Paicord supplies current JSON/zstd and 40/41 cross-checks. Swiftcord v1 supplies
the historical JSON/zlib and opcode-1 subset and has no 13, 37, 40, or 41.

Current first-party Identify normally uses capability bitfield `1734653`; the
clean account received `1767421` because the first-party
`private_channel_obfuscation` experiment adds bit 15. As rechecked on 13 August
2026, SakuraCord now advertises `1767421`: its existing Ready Supplemental path
hydrates `lazy_private_channels` from the supplemental user table, merges them
with ordinary private channels, applies the same last-message ordering, and
reconciles subsequent channel/message Gateway events. Discord's public Gateway
documentation does not define user-client capability bit 15. The current web
bundle supplies the operational contract. Pinned Paicord declares capability
bits only through 14 and 16 and leaves `ReadySupplemental` empty; pinned
Swiftcord v1 has no corresponding capability or supplemental implementation.
Their absence was treated as an explicit compatibility gap, not as evidence to
omit the current first-party shape.

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
  A 4 August 2026 follow-up found two desktop-specific decoding boundaries.
  ETF can represent a permission bitfield as an integer even though Discord's
  public JSON guild schema uses a string. More importantly, current first-party
  build `587597` handles Guild Create as an envelope with `id`, `data_mode`, and
  guild identity nested under `properties`, while the public event description
  and pinned Paicord model remain flat; pinned Swiftcord v1 has no corresponding
  current handler. A private sanitized SakuraCord diagnostic recorded the
  failed live join as sequence 131 `GUILD_CREATE`, followed by guild catalog and
  member activity, proving the event arrived but its identity was not decoded.
  Gateway Ready and Guild Create now accept flat or nested identity plus string
  or integer permissions. Missing collections in a partial event preserve the
  existing channel and role catalogs. Current-shape fixtures prove the guild and
  rail entry reconcile without a compensating REST request.
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
  DAVE-capable voice state machine;
- for each explicitly started or watched Go Live stream, a separate Voice v8
  Gateway/DAVE/UDP connection at the endpoint supplied by
  `STREAM_SERVER_UPDATE`. It identifies with the main voice session ID, the
  stream RTC server/channel IDs, and one `screen` video stream. It neither
  opens another microphone nor plays the voice channel's audio; and
- unauthenticated HTTPS media GETs to `cdn.discordapp.com` and
  `media.discordapp.net` for server-returned or locally derived Discord asset
  paths. These loads use an isolated ephemeral URLSession with memory-cache
  semantics and cookie storage explicitly disabled. They carry no
  Authorization, client-properties, fingerprint, installation ID, or
  routing-key headers and use a shared coalescing/cancellation queue. Inline
  linked images are accepted only on those exact HTTPS hosts, without
  credentials or a custom port; SakuraCord does not fetch arbitrary
  third-party link previews.
- unauthenticated GIF-picker media GETs use the response-provided HTTPS
  origins, without credentials or a nonstandard port, matching the current
  first-party picker rather than Discord's separate asset-action host helper.
  Response-provided and locally derived media URLs pass this transport-safety
  policy before any image loader or AVFoundation use. These GETs use the same
  isolated ephemeral, cookie-free,
  bounded coalescing/cancellation queue as Discord media. Native video is
  streamed through that queue to an app-controlled temporary file before
  AVFoundation opens the local file; AVFoundation never receives a remote
  URL. Tenor WebM results may use corresponding MP4 and GIF representations.
  Klipy results use the response-provided WebP directly; SakuraCord does not
  invent an MP4 URL by changing the Klipy WebM extension. A visible result
  creates at most three distinct media requests. Cell reuse, viewport exit,
  or picker dismissal cancels
  waiters and removes staged video files. No Authorization, client metadata,
  fingerprint, installation, Discord routing, or cookie header is added.

The current official desktop and SakuraCord use ETF with `zstd-stream` for the
main Gateway. The public web client uses JSON with compressed Gateway
transport, Paicord uses JSON plus zstd, and Swiftcord v1 uses historical JSON
plus zlib.

## Authentication

Native authentication is implemented without an embedded Discord login page:

- a cold password login performs the Apex installation preflight, the
  installation-bearing fingerprint preflight, login, then connects Gateway;
  when Apex fails or omits its installation, that same fingerprint preflight
  resolves the required fingerprint without an installation header before
  login and retains an installation only when Discord returns one;
- a warm password login performs login and then connects Gateway;
- an approved QR credential or stored credential missing only its installation
  identity performs one best-effort unauthenticated Apex lookup and, only if
  needed, one `/experiments` fallback before connecting Gateway without
  replaying login; when both omit it, Gateway Identify omits the optional field;
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
  channel change. A clean-client CDP rapid-navigation trace on 10 August showed
  three dispatched `limit=10` reads all finishing after their selections were
  superseded; SakuraCord therefore cancels only stale presentation and lets the
  bounded transport reads finish into its provider caches. Discord's public
  message documentation defines the endpoint, permissions, and pagination
  parameters but does not prescribe client cache or cancellation lifetime.
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
- A loaded message link navigates locally. An absent target uses one bounded
  channel-history GET with `around={message_id}&limit=50`. That response
  replaces the presented window instead of merging with a potentially distant
  newest page. Scrolling beyond either loaded edge extends only that contiguous
  window with `before={oldest_loaded_message_id}&limit=20` or
  `after={newest_loaded_message_id}&limit=20`; it never fabricates adjacency
  across an unloaded range. Gateway arrivals remain outside a historical
  window until forward pagination reaches them or the user returns to the
  newest window.

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
  contains an author absent from that store, SakuraCord resolves at most 200
  unique user IDs, with newest authors and reply authors prioritized before
  mentions. Discord's 100-ID opcode 8 limit is preserved by issuing at most two
  disjoint batches concurrently with `presences: false`, then merging their
  results in source-batch order. The request deliberately omits `nonce`, as
  do Discord's current `requestGuildMembers` implementation and pinned
  Paicord; the response is reconciled against its guild plus the union of
  returned member IDs and `not_found` IDs. IDs already cached or requested in
  the current Gateway session are omitted. The app performs a supplemental
  bounded lookup only when a locally retained timeline contains rows outside
  the provider-completed fresh page, matching the official web client's
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
- Explicit quick-switcher `@` searches rank the account-wide local UserStore,
  then opportunistically hydrate the selected guild. After a cancellable
  debounce, one opcode-8 payload contains the selected guild as a one-element
  `guild_id` array, the lowercased prefix in `query`, `limit:100`,
  `presences:true`, and `user_ids:null`; it has no nonce.
  Incoming `GUILD_MEMBERS_CHUNK` events immediately extend the session-local
  user and per-guild nickname indexes, which re-rank the retained sheet without
  blocking the keystroke path. Ordinary unmodified searches send nothing, and
  no member-search result is restored from disk on relaunch. This was rechecked
  on 14 August 2026 against the clean authenticated stable client. Three CDP
  captures with uncached query strings each observed exactly one matching
  Gateway frame 431–523 milliseconds after filling the field, with the shape
  above and no REST request. Discord's public bot Gateway contract documents
  one guild ID rather than the first-party client's single-element array.
  Pinned Paicord models a single `GuildSnowflake` and has no account-wide
  quick-switcher requester; pinned Swiftcord v1 has neither this request nor a
  corresponding quick-switcher member search. Those absences were checked
  explicitly and do not override current first-party behavior.
- The channel member inspector always retains the official client's initial
  `0...99` member-list range, then adds only the 100-aligned blocks intersecting
  the visible rows plus half a viewport of prefetch on either side. A payload
  contains at most five range pairs, subscriptions use a five-member-list-ID
  LRU, and scrolling samples the latest viewport at most once every 300
  milliseconds. Channels with the same permission view share one list ID and
  one request-budget slot. The server-provided `member_list_id` is
  authoritative; its deterministic permission-overwrite hash is used only as
  the first-party-compatible fallback. Equal range sets for the same list ID
  are not resent. Each update remains one guild-scoped opcode-37 payload
  containing one representative channel per retained list ID. It is not an
  opcode-8 member request, REST read, or account mutation.
  `GUILD_MEMBER_LIST_UPDATE.id` routes operations and authoritative group order
  and counts into separate per-ID accumulators. Changing between a public and
  permission-overwritten channel immediately selects that accumulator, so
  revisiting a public channel cannot retain a restricted channel's members or
  counts. Loaded members retain their absolute Gateway list indexes. The
  renderer preserves `MemberSection.make` order and keeps unresolved capacity
  after the currently loaded members in each authoritative section, so sparse
  Gateway indexes cannot create blank rows between already resolved members.

  This contract was statically rechecked on 5 August 2026 against current
  first-party asset `web.1f98726096a7c0ce.js` (SHA-256
  `592320633d203814eb03f5127552985ca335bb9e4c7eb3ab3aa0a76a0173c80a`).
  Its modules `36124`, `361610`, and `63238` respectively establish the
  100-row block and initial range, half-viewport/100-boundary range planning,
  and equality-deduplicated subscription store. Module `202613` preserves the
  server `memberListId`; otherwise it returns `everyone` for a public
  permission view or the unsigned MurmurHash3 value of sorted `allow:<id>` and
  `deny:<id>` VIEW_CHANNEL overwrite entries.
  Pinned Paicord's `GuildMemberList.swift` independently keeps `0...99`, adds
  viewport-derived 100-row blocks with at most three pairs, and debounces for
  300 milliseconds. Its `GuildStore` stores accumulators and a bounded
  subscription LRU by member-list ID, converts each ID to one representative
  channel for the wire payload, and applies an update only to the accumulator
  matching `update.id`. Its `ChannelStore` uses the same server-ID-first,
  permission-hash fallback. Pinned Swiftcord v1 has no opcode-37, member-list
  ID, member-list update, or virtual member-range implementation.
  Discord's current public Gateway documentation describes the distinct
  opcode-8 Request Guild Members contract, a 4,096-byte payload ceiling, and
  120 outgoing Gateway events per 60 seconds, but does not document opcode 37
  or `GUILD_MEMBER_LIST_UPDATE`. Static first-party behavior was unambiguous,
  so no authenticated traffic capture was required to resolve protocol shape.
- Nameplate media follows the current first-party SKU asset resolver. A decoded
  `collectibles.nameplate.sku_id` maps to
  `https://cdn.discordapp.com/media/v1/collectibles-shop/{sku}/static` for the
  resting frame and the sibling `/animated` asset for hover. Response-provided
  asset URLs and the historical asset-path convention remain compatibility
  fallbacks only when `sku_id` is absent. Discord's public User resource defines
  `sku_id`, `asset`, `label`, and `palette`. Current first-party asset
  `web.1f98726096a7c0ce.js` modules `746002`, `253292`, and `174755` establish
  the SKU URL, static-first presentation, and hover animation selection. Pinned
  Paicord still derives `assets/collectibles/{asset}/static.png` and `img.png`;
  that historical path fails for some current nameplates. Pinned Swiftcord v1
  has no collectibles/nameplate implementation. This was statically rechecked
  on 5 August 2026 after a live SakuraCord member showed an absent resting asset
  but a working hover animation.
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
- A user-selected server notification or mute change sends one immediate
  `PATCH /users/@me/guilds/settings` through the same central transport. Its
  body contains one guild ID under `guilds` and only the selected
  setting. In addition to `message_notifications`, or `muted` plus
  `mute_config`, the server-only menu supports `suppress_everyone`,
  `suppress_roles`, `notify_highlights`, `mute_scheduled_events`, and
  `mobile_push`. The four Boolean settings are sent directly. Suppress
  Highlights maps to Discord's highlight enum `DISABLED` (`1`) when selected
  and `NULL` (`0`) when cleared; `ENABLED` is `2`. Ready and
  `USER_GUILD_SETTINGS_UPDATE` decode and retain all five fields. A server
  “Mark as Read” action sends only SakuraCord's currently unread, accessible
  channel and joined-thread states to `POST /read-states/ack-bulk`, with at
  most 100 entries in each sequential request. The UI applies those read
  boundaries optimistically and rolls them back on failure; notification
  settings apply locally only after success. Authoritative
  `USER_GUILD_SETTINGS_UPDATE` events still reconcile notification state.
  This contract was statically checked on 2026-08-04 against Discord public
  web build `588119` and asset `web.1f98726096a7c0ce.js`, Discord's current
  public rate-limit and status-code documentation, Paicord revision
  `694761c1938b73bb60bd58942674dfe73aab1135`, and Swiftcord v1 revision
  `14465d927ebe1ba34b3befa00f9365fad7b56eb9`. The public documentation does
  not describe either user-client route. Paicord's server-icon menu only
  copies the guild ID and neither pinned reference implements these server
  mutations. No authenticated request or traffic capture was used.
  The expanded server settings contract was statically rechecked on
  2026-08-15 against Discord's clean public asset
  `web.4e1d701f13b1b022.js` (SHA-256
  `593cfe3632fae5d3dd86ee87d4e92c2699e8ddd43271f87b617e655ff734ec28`),
  which exposes the bulk route, partial-body action, exact field names,
  defaults, store accessors, and highlight enum, plus Discord's current public
  Notifications Settings help article. The same pinned Paicord and Swiftcord
  revisions still have no comparable server settings mutations. No
  authenticated account action or traffic capture was used for this recheck.
- A category is a first-class user-guild-settings override keyed by its
  category channel ID; changing it does not rewrite or mute any child channel's
  server-side override. A category notification selection sends one immediate,
  single-attempt `PATCH /users/@me/guilds/settings` whose `guilds` object
  contains exactly one guild and whose `channel_overrides` object contains
  exactly one category with `message_notifications`. Child channels without a
  direct setting inherit that category value at notification-decision time,
  while direct child overrides remain authoritative for their own setting.
  Category mute sends only `muted` and `mute_config`; it suppresses
  notifications inherited by the category's child channels and joined threads
  without making those child channel overrides muted, suppressing their own
  unread styling, or inferring a collapsed presentation. Unread children of a
  muted category remain visible as unread inside the server but do not produce
  the server-rail unread marker. Manual category collapse/expand updates the
  sidebar optimistically and sends only the `collapsed` field. SakuraCord keeps
  at most one collapse PATCH in flight per category; further toggles replace a
  single queued desired value, so only the latest differing state is sent after
  the in-flight request. A rejected request restores the last confirmed state.
  The sidebar otherwise follows the authoritative field independently from
  mute state. Ready and `USER_GUILD_SETTINGS_UPDATE` decode all four fields
  from the category override. “Mark Category as Read” sends only unread,
  accessible direct children and joined threads whose parent belongs to the
  category through the existing `POST /read-states/ack-bulk` batching contract.
  The category menu otherwise mirrors the channel menu but omits Copy Link.

  This contract was statically checked on 2026-08-07 against Discord public web
  build `589089`, version hash
  `cf63e91c5378d3376ec2c615530e8ae0706aed51`, and clean public asset
  `web.3cd0f98a15f63be2.js` (SHA-256
  `a77974b18a92b7d5452d4138b0b276f380ac498fd7fefa1b9aa7e183ace0f4f0`),
  Discord's public channel-type, status-code, Gateway, and rate-limit
  documentation, Paicord revision
  `694761c1938b73bb60bd58942674dfe73aab1135`, and Swiftcord v1 revision
  `14465d927ebe1ba34b3befa00f9365fad7b56eb9`. The current signed and notarized
  Discord desktop 0.0.406 presentation and the supplied 2026-08-07 category
  menu screenshot confirmed the visible menu shape; no category setting was
  changed in an authenticated account and no traffic was captured. The public
  API documentation identifies guild categories as channel type 4 but does not
  document these user-client settings or acknowledgement routes. Paicord has
  local category collapse presentation only, and neither pinned reference
  implements category notification, mute, or bulk acknowledgement mutations.
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
  20-message page with `before={oldest_loaded_message_id}&limit=20`; after that
  page is incorporated, the banner grows with the discovered unread rows
  (`120+`, `140+`, and so on). Each additional page requires further user
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
  notifications use the same decision. An effective `message_notifications`
  value of `2` (Nothing) suppresses every native alert and sound, including
  direct-user, role, and `@everyone`/`@here` mentions, without erasing unread
  or mention badges. Native notifications support foreground presentation and
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
  `X-Context-Properties` location is `chat_input`. Reply-author notifications
  are enabled by omitting `allowed_mentions`; disabling them adds the complete
  `parse:["users","roles","everyone"]`, `replied_user:false` object so
  ordinary content mentions retain their default parsing. Concurrent calls
  with the same channel and nonce share one in-flight mutation.
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

### Go Live screen sharing

The dated 20 and 22 August evidence above establishes two distinct control planes:
the main Gateway owns stream discovery and viewer intent, while a separate
Voice v8 connection owns each selected screen media session.

The following matrix is the redacted action-to-payload sequence observed in the
authenticated private-call capture. Angle-bracketed values denote a stable
redaction category, not literal traffic.

| Surface and UI action | Exact observed network sequence and result |
| --- | --- |
| DM, start call | Main Gateway opcode 4 with `guild_id:null`, `<CHANNEL_ID>`, current mute/deafen/video, `flags:0`, `preferred_region:"warsaw"`, and ordered `preferred_regions`; receive `CALL_CREATE`, own `VOICE_STATE_UPDATE`, then send `POST /api/v9/channels/<CHANNEL_ID>/call/ring` body `{"recipients":null}`; receive `VOICE_SERVER_UPDATE`, `CALL_UPDATE`, and HTTP `204`. |
| GDM, start call | Same guildless opcode-4 voice join and pushed call/voice events; the group start performs the ring mutation without the DM readiness read. Selecting the existing GDM before a call was active also sent main opcode 13 `{"channel_id":"<CHANNEL_ID>"}`. |
| DM or GDM, join existing call | Main opcode 4 with the private channel and region preferences; receive own `VOICE_STATE_UPDATE`, `CALL_UPDATE`, and `VOICE_SERVER_UPDATE`; no ring mutation. Call Voice then identifies and negotiates as described below. |
| DM or GDM, leave | Main opcode 4 with `channel_id:null`, `guild_id:null`, current mute/deafen/video, and `flags:0`; receive own null-channel `VOICE_STATE_UPDATE`; the call remains while another participant is present. |
| DM or GDM, last participant leaves / end | The same null-channel opcode 4 and voice-state update, followed by `CALL_DELETE {channel_id:<CHANNEL_ID>}`; the Voice WebSocket closes and media resources are released. |
| DM or GDM, start sharing | Main opcode 18 `{"type":"call","guild_id":null,"channel_id":"<CHANNEL_ID>","preferred_region":"warsaw"}` immediately followed by opcode 22 `{"stream_key":"call:<CHANNEL_ID>:<OWNER_ID>","paused":false}`; receive `STREAM_CREATE`, `VOICE_STATE_UPDATE self_stream:true`, then `STREAM_SERVER_UPDATE`; open a separate stream Voice connection. |
| Broadcaster, stop sharing | Main opcode 19 with only `stream_key`; stream Voice opcode 12 becomes inactive; receive `STREAM_DELETE` and `VOICE_STATE_UPDATE` without `self_stream`; close only the stream Voice connection. Official self-stop used reason `user_requested`; a remote broadcaster ending while watched used `stream_ended`. |
| DM, remote share becomes available | On the remote `VOICE_STATE_UPDATE self_stream:true`, the connected viewer automatically sends main opcode 20 with the `call:` key before its `STREAM_CREATE`; it then receives `STREAM_CREATE`/`STREAM_SERVER_UPDATE` and opens stream Voice. This occurred in both broadcaster/viewer role directions. |
| DM, manually stop viewing | Main opcode 19 with only the watched key; receive `STREAM_DELETE reason:user_requested`; close the viewer's stream Voice connection but remain in the call. |
| DM, manually rejoin | Main opcode 20 with only the key; receive a new `STREAM_CREATE`/`STREAM_SERVER_UPDATE`; open a fresh stream Voice connection. |
| GDM, remote share becomes available | No opcode 20 and no stream Voice connection were emitted automatically. The official UI presented `Watch Stream`; this is a verified behavioral difference from one-to-one DMs. |
| GDM, Watch Stream | Optional preview GET and main opcode 20; receive `STREAM_CREATE` then `STREAM_SERVER_UPDATE`; open stream Voice and send viewer demand. |
| GDM, Stop Watching / rejoin | Opcode 19 produces `STREAM_DELETE reason:user_requested` and closes stream Voice; the later Watch action sends opcode 20 again and creates a fresh stream Voice allocation. |

The call and stream Voice handshakes used WebSocket v9 framing with a Voice v8
Hello. Identify opcode 0 included the main voice `session_id`, DAVE maximum 1,
`video:true`, and video RIDs (`100`/`50` for calls, `100` screen RID for a
stream). Ready opcode 2 offered AES-GCM and XChaCha20-Poly1305 RTP-size modes and
the `fixed_keyframe_interval` experiment. Select Protocol opcode 1 advertised
Opus plus AV1 decode-only, H.265, H.264, and VP8 in the official client; the
official broadcaster negotiated H.265, while interoperability with SakuraCord's
advertised H.264 negotiated H.264. Session Description opcode 4 selected
`secure_frames_version:1` and `dave_protocol_version:1` in every captured media
session. A 2560×1440 60 FPS screen was advertised by Voice opcode 12 with
`max_bitrate:9000000`. Viewer demand used opcode 15 quality 100 with a
`pixelCounts` hint; hidden/unwatched content used zero demand.

SakuraCord applies that advertised maximum to VideoToolbox's one-second
data-rate window. The RTP sender derives its wire pacing rate from the encoded
payload plus the actual RTP/encryption overhead and ten percent drain headroom;
the headroom empties transport work between frames without increasing encoder
output or the sustained media rate. It paces each encoded frame in approximately
five-millisecond UDP batches rather than enqueueing a complete high-motion frame
at once, with at most 100 milliseconds of accumulated pacing credit so a scene
change or keyframe is not unnecessarily stretched across the receiver's frame
assembly deadline. Screen capture admits at most two frames between VideoToolbox
and completed UDP delivery. When transport is slower than capture, it skips new
capture input before encoding instead of discarding encoded H.264 reference
frames; an unexpected encoder/stream loss forces the next frame to be a keyframe,
as does a receiver PLI. Call audio and stream video use Network.framework's
interactive-voice and interactive-video service classes respectively. Captured
Opus queues retain at most the newest three 20-millisecond frames and preserve
the source sample offset in the RTP clock when an older frame is discarded, so
transport backpressure cannot grow into delayed microphone or sound-share audio.

- Stream keys are `guild:{guild_id}:{channel_id}:{owner_id}` or
  `call:{channel_id}:{owner_id}`. Starting sends opcode 18 `STREAM_CREATE` with
  `type`, nullable `guild_id`, `channel_id`, and nullable `preferred_region`.
  Watching one stream sends opcode 20 `STREAM_WATCH`; leaving that stream or
  ending a local broadcast sends opcode 19 `STREAM_DELETE`. Opcode 21
  `STREAM_PING` retains an interrupted allocation during reconnect, and opcode
  22 `STREAM_SET_PAUSED` carries `stream_key` plus `paused`. These explicit
  watch/leave operations never leave the surrounding voice channel. A connected
  one-to-one DM call automatically watches a discovered remote `call:` stream
  initially; the viewer may subsequently stop watching or rejoin it. Group DMs
  and guild voice channels retain explicit per-stream watch and leave controls
  without the one-to-one call's automatic initial watch.
- `STREAM_CREATE` carries the stable key plus optional region, viewer IDs, RTC
  server/channel IDs, and pause state. `STREAM_UPDATE` changes region, viewers,
  or pause state without replacing absent fields. `STREAM_SERVER_UPDATE`
  supplies the key, nullable endpoint, and token; a null endpoint means wait for
  replacement allocation rather than deleting the stream. `STREAM_DELETE`
  carries the key plus optional unavailable/reason state and tears down only
  that stream's media and decode resources. When `unavailable` is true, the
  stream remains reconnecting: SakuraCord retains the local capture or explicit
  viewer intent, sends `STREAM_PING`, and attaches the replacement stream RTC
  allocation instead of treating the event as a terminal stop.
- The stream Voice Identify uses the current user's main voice `session_id`,
  `server_id = rtc_server_id`, `channel_id = rtc_channel_id` (the current client
  also tolerates Discord's numeric `rtc_server_id - 1` fallback), DAVE maximum,
  `video:true`, and a `screen` RID. A broadcaster advertises screen H.264 with
  Voice opcode 12. A viewer requests the chosen SSRC at quality 100 with Voice
  opcode 15, includes the rendered tile's `pixelCounts` hint, and sends zero
  demand when the share is hidden or unwatched. Incoming sink-wants payloads
  may include that nested `pixelCounts` map; the broadcaster ignores it for
  aggregate on/off demand without rejecting the opcode.
- Optional stream audio uses the stream Voice connection's negotiated audio
  SSRC and normal DAVE-protected Opus RTP. Before sending it, the broadcaster
  announces Voice opcode 5 with the Soundshare flag (`1 << 1`), which carries
  contextual video audio without a microphone speaking indicator. It sends
  five Opus silence frames before becoming inactive. A viewer decrypts this
  audio in the stream session and routes it into the existing call playback
  engine rather than opening a second microphone or output graph.
- `GET /streams/{stream_key}/preview?version={milliseconds}` returns a nullable
  CDN URL used only as lightweight pre-join presentation. It is a retry-safe
  read under the shared scheduler. A first-party broadcaster may additionally
  post a bounded JPEG data-URL thumbnail to the same preview family; SakuraCord
  does not need that mutation for media delivery and does not invent or retry
  it.
- Main-Gateway opcode 4 now carries guild/channel, mute/deafen, and
  `self_video`; the current first-party client does not send the older fixed
  `self_stream:false` field. Remote/local active-share presence is instead
  projected from pushed voice-state `self_stream` and the stream event store.

Screen source selection is an Apple framework boundary, not a Discord
protocol. SakuraCord prepares `SCContentSharingPicker` when the preview opens
but creates no capture stream until the user explicitly chooses a source. A
picker cancellation returns to the source-less preview; dismissing the preview
releases the picker observer. Once selected, SakuraCord owns one `SCStream`,
updates its content filter/configuration in place for source or quality changes,
accepts only complete IOSurface-backed screen frames, and optionally captures
48 kHz stereo source audio while excluding SakuraCord's own process audio. It
keeps preview delivery enabled while the preview overlay is presented, including
while the system picker temporarily owns key-window focus. It
releases picker, stream, preview, audio/video encoders, decoder, and transport
resources on popup dismissal, stop, failure, source removal, or disconnect.

### Private calls

The private-call contract was authenticated and dynamically rechecked on 22
August 2026 as described above, superseding the static-only 29 July evidence.
The earlier web-build, Paicord, Swiftcord, DiscordKit, public Gateway, and public
voice-connection checks remain corroborating sources. Paicord exposes opcode
13 and the `CALL_*` event family but its pinned call handler is incomplete and
predates the current `ongoing_rings` field. Swiftcord v1 and DiscordKit supply
only the historical guild-optional voice-state path.

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
  no ring mutation. A complete call snapshot with neither participants nor
  ongoing rings is not considered an existing call and therefore follows the
  start path instead of silently joining. The join path subscribes with opcode
  13 and joins with opcode 4. Accepting an incoming call is the same join path.
  Declining sends exactly one
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

For work that is not exclusively UI, a read-only authenticated verification
pass against a configured session is encouraged when it can exercise the
changed behavior. It complements rather than replaces deterministic coverage.
Connection and session-maintenance traffic, reading existing state, navigation,
and sanitized diagnostics are allowed. Agent-run verification must not
deliberately mutate remote account state or content, including sending, editing,
or deleting messages; creating DMs; adding reactions; changing settings;
joining or leaving; moderation actions; calls; or login and challenge flows.

Account-mutating live verification requires an explicit user request for the
specific bounded action. Re-audit the exact API path and add meaningful mocked
contract coverage before performing it. If no configured authenticated session
is available, report that the live pass was not performed; do not extract or
copy a credential to create one.

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
