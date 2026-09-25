# Discord production protocol baseline

Last repository audit: 30 August 2026, in a working tree based on SakuraCord
commit `369357e`.

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

Profile-editor research on 5–6 September 2026 refreshed the shared transport
metadata against a separately installed clean stable desktop client: web build
`607562`, desktop `0.0.408`, native updater `89799`, Electron `42.7.1`, and
Chromium `148.0.7778.280`. Its captured client hints contain
`"Not/A)Brand";v="99", "Chromium";v="148"`. The current baseline uses these
observed versions; the earlier feature audits retain their own observation
dates. Application focus covers every SakuraCord window, including Settings;
the main chat window's read-acknowledgement eligibility remains separate.
Native language preferences and the platform's canonical time-zone identifier
can differ from Electron's browser defaults and legacy ICU aliases. Session,
heartbeat, launch, and installation identifiers remain owned by each client.

Profile-editor interaction was rechecked on 9 September 2026 using authenticated
CDP capture in clean stable web build `608660` (`861472c`), desktop `0.0.411`,
and native updater `89799`. Reopening the editor and revisiting a server reused
profiles fetched within 60 seconds; stale entries refreshed without hiding the
cached profile. The current first-party fetcher also coalesces in-flight reads
by user and server. Main-profile pronouns saved independently on both full-Nitro
and free accounts. The free account could save `accent_color` as an sRGB integer
and restore its original null value, and could add a game widget through the
ordinary ordered-list `PUT /users/@me/widgets` route. Game and application
widgets do not require the personal-widget Nitro/rollout entitlement; creating
or changing personal widgets and uploading their images still do. Existing
personal widgets may be retained unchanged when editing the rest of the board.
The same clean build omits new personal widgets without section content from
the save payload. Once content exists, a widget name is required to save.
Blank and partially completed widgets remain removable, with the ordinary
removal confirmation. Saving prunes empty fields and sections; adding empty
blocks to an existing saved widget still activates its unsaved-change controls.
All temporary text, color, and widget changes were restored and re-read. The
pinned Paicord and Swiftcord sources have historical profile caching but no
comparable complete editor; current first-party interaction is authoritative.

No token, cookie, authorization header, message body, personal payload,
fingerprint, installation identifier, or unsanitized traffic is stored in this
repository. Treat every build number and observed payload as a dated snapshot,
not current official behavior.

Pinned messages were re-audited on 30 August 2026 in a renamed clean official
Discord desktop `0.0.408` with Chromium 148 and CDP attached before the main
Gateway resumed. The bounded study used 26 numbered disposable messages in
`#general` on the private test server, then removed those messages and every
generated pin announcement. Opening pins issued
`GET /api/v9/channels/<CHANNEL_ID>/messages/pins?limit=25`; the full first page
returned HTTP 200 with 25 `items`, `has_more:true`, and descending `pinned_at`
values. Loading the next page issued the same route with
`before=<LAST_PINNED_AT>&limit=25` and returned the one remaining item with
`has_more:false`. The messages had deliberately different creation and pin
orders, and the UI and response both followed newest pin time rather than
message creation time. The final empty read returned `items:[]` and
`has_more:false`.

The unprivileged test account could send and delete its own messages but its
central message menu omitted Pin Message. The server-owner account exposed Pin
Message, and a pinned row exposed dedicated Jump and Unpin actions. Each
confirmed pin sent one empty-body
`PUT /api/v9/channels/<CHANNEL_ID>/messages/pins/<MESSAGE_ID>` and received HTTP
204; unpin used the corresponding empty-body `DELETE` and also received HTTP
204. Neither request carried an audit-log reason. The desktop Gateway negotiated
`encoding=etf`, version 9, and `compress=zstd-stream`. A pin produced an ordinary
`MESSAGE_UPDATE` with `pinned:true`, a `CHANNEL_PINS_UPDATE` with the newest pin
timestamp, and a type-6 pin-announcement `MESSAGE_CREATE`; their relative arrival
order was not stable across samples. Unpin produced `MESSAGE_UPDATE` with
`pinned:false` and `CHANNEL_PINS_UPDATE`; removing the final pin supplied a null
last-pin timestamp and did not create a system message. Deleting a still-pinned
message produced only `MESSAGE_DELETE` in the observed channel and no
`CHANNEL_PINS_UPDATE`.

No credential, cookie, authorization value, account, guild, channel, message
identifier, message content, or raw Gateway/response payload was retained. The
1–50 documented limit and `VIEW_CHANNEL`/`READ_MESSAGE_HISTORY` read behavior
were cross-checked against Discord's current public message documentation; the
dedicated `PIN_MESSAGES` mutation permission and deletion exception were
cross-checked against the current permission, change-log, and Gateway
documentation. The pinned Paicord and Swiftcord v1 sources contain only
historical pin state/action fragments and were not used to override the current
paginated route.

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

Screen sharing was re-audited on 20 August 2026 against a clean, authenticated,
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
pinned Swiftcord v1 contains no matching screen-sharing implementation. Those sources
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

The profile-image GIF path was separately checked on 6 September 2026 in
clean desktop build `607562`/`0.0.408`. Unlike result thumbnails, cropping
loads the response's editable `gif_src` through `https://discord.com/tenor`,
`/giphy`, or `/klipy`, preserving the validated provider path and dropping
its query. Other approved HTTPS image origins retain their supplied URL.
The official picker starts this image fetch before dispatching an independent
`POST /gifs/select` with `id` and the current query `q` (empty for Trending).
That notification is not awaited by image selection and must not make a valid
image unusable if it fails. The image download retains normal cancellation;
the notification has one attempt. This profile-only contract does not change
the message picker's result-media or sending path.

Main and server profile editing was researched on 5–6 September 2026 against
the separately installed, unmodified desktop build `607562`/`0.0.408`, with CDP
attached before interaction. The editor uses its own `type=modal` profile read,
separate from the existing popover read below. Identity, metadata and server-tag
changes retain their distinct routes and execute sequentially; widget saving
is an independent group. Unchanged fields are omitted. Empty edited text is an
empty string, while image removal and server inheritance use the field-specific
null representation. Server theme reset sends two ordered null endpoints and can
return a single null theme; effect/frame removal sends an empty SKU array.
The main profile has no theme reset action. Editing either colour sends both
displayed endpoints. Unset theme colours are derived from the avatar's first
two median-cut palette entries, using the clean client's 80-point asset request
at the display scale; they are not a fixed default gradient.
The server-member response can omit `avatar_decoration_data` after a null clear.
That observed omission is accepted only for this operation, rather than making
all missing saved fields valid.

Image uploads send the cropped data URI and an `X-Discord-Original-MD5` value
computed from the selected source bytes. The header's field name distinguishes
`user_default_profile_avatar`, `user_guild_profile_avatar`,
`user_default_profile_banner` and `user_guild_profile_banner`. Reusing an
unchanged history image sends only `avatar_id`; editing that crop creates a new
upload. Avatar upload descriptions retain the source name and local edit time.
Widget images first allocate storage and upload bytes, then save the returned
reference in the widget list. Native image encoders can produce different bytes;
crop geometry, animation, source hash, MIME type and resulting appearance remain
separate verification requirements.

Widget eligibility uses `READY.apex_experiments`, experiment
`2026-07-personal-widget` (hash `2369760879`) in the current account's assignment.
Variants 1 and 2 permit editing only with full Nitro (`premium_type=2`); variant
2 exposes creation, and the eligibility-only flag (`flags & 8`) does not grant
access. Missing or unknown assignments fail closed. Collectibles are resolved
from catalogue variants and owned purchases; a Nitro inclusion alone does not
grant an unowned item. Purchase type 7 additionally requires full Nitro.
Unavailable owned-frame and other-account entitlement branches were not
exercised with the configured account. Activity, Wishlist, purchase and general
connected-account mutation paths are outside this profile editor's scope.

The same profile audit rechecked the pinned Paicord, Swiftcord v1 and DiscordKit
revisions above. Paicord corroborates profile reads, main/server cosmetic
response models and protobuf status fields, but its settings write helpers are
unimplemented and its generic current-user payload contains only username,
avatar and banner. Swiftcord v1 and DiscordKit corroborate the version-1
settings-proto route; Swiftcord also sends an immediate Gateway presence update,
which is not evidence for the current official client's invisible-status flow.
None supplies the current complete editor, avatar-history, display-name-style
or custom-widget write contract. Discord's public
[user reference](https://docs.discord.com/developers/resources/user) corroborates
the premium tiers, nullable user cosmetics and primary-guild response fields;
its [image reference](https://docs.discord.com/developers/reference#image-formatting)
corroborates CDN asset formats. These are supporting sources, while the dated
official-client actions and modules establish the undocumented editing flows.

The emoji-picker favourite and context-menu paths were statically re-audited
on 29 August 2026 against clean public web build 603738 and production asset
`web.e3526df05a0a7718.js` (SHA-256
`8bc467463c6546ee99bae959e4ae614fe4df5b7ae4fdb0d79eacdb149553eb31`).
First-party module `554375` adds and removes ordered `favoriteEmojis` values
through the Frecency settings manager with a 250-item ceiling, while picker
context-menu module `233503` exposes the native-copy, custom-ID, and custom
image-link actions.

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

### Server invites and membership (22 September 2026)

Authenticated CDP experiments in Discord Official Fresh desktop `0.0.411`,
using both saved accounts exclusively in the owner-designated testing server,
confirmed invite resolution, acceptance, leaving, invite creation/expiry/revocation,
and a banned-account rejection followed by unban and rejoin. The production asset
was `web.9a6d63589ff469f3.js`, SHA-256
`459b4591cde285a42759be68941b2096491c14f8654fca35bf72d9c45cbee737`.
Relevant public contracts are [Invite](https://docs.discord.com/developers/resources/invite)
and [Leave Guild](https://docs.discord.com/developers/resources/user#leave-guild).
Pinned Paicord corroborates accept/leave routes and optional Gateway `session_id`,
but lacks the current complete invite-card workflow. Pinned Swiftcord v1's join
view resolves an invite without implementing acceptance; it is not a behavioral
reference for completed joining.

- Preview: `GET /invites/{code}` with `with_counts=true`,
  `with_expiration=true`, and `with_permissions=true`. A banned account can still
  resolve an otherwise valid preview. Invalid invites returned code `10006`;
  expired and revoked invites both returned `50270`. These expected failures
  must not trip the account-wide networking circuit.
- Accept: one `POST /invites/{code}` with the current Gateway `session_id`;
  message-card actions additionally supply `invite_instance_id` as
  `{messageID}:{code}`. Context location is `Join Guild` or
  `Invite Button Embed`, with destination guild/channel IDs and numeric channel
  type. No fabricated installation or analytics identifiers are added.
  The response contains guild/channel and `new_member`, but need not contain
  profile or counts. Preserve the preview. The observed `GUILD_CREATE` was
  dispatched before acceptance completed; either order must work.
- Join CAPTCHA (23 September follow-up): the same first-party asset's HTTP
  interceptor recognizes HTTP 400 `captcha_key`, presents the challenge, and
  resubmits with `X-Captcha-Key`, optional `X-Captcha-Rqtoken`, and optional
  `X-Captcha-Session-Id`. Its extractor also supplies `captcha_sitekey`,
  `captcha_service`, `captcha_rqdata`, and `should_serve_invisible` to the widget.
  Pinned Paicord's `DefaultDiscordClient` corroborates these response fields and
  headers; pinned Swiftcord v1 only embeds web authentication and has no native
  join-challenge continuation. Public Invite documentation does not specify
  this private-client challenge contract. The existing hCaptcha integration
  uses the response site key and rqdata, the Discord origin, and the documented
  [normal/invisible widget modes](https://docs.hcaptcha.com/configuration).
  SakuraCord permits a supported hCaptcha response only on the invite acceptance
  route without stopping account networking. One human completion resubmits the
  original body/context once, on the same provider and Gateway session, with
  no automatic retry. Cancellation, account invalidation, empty solutions,
  another challenge, and ambiguous failures terminate that attempt. This
  bounded replay is a deliberate difference from the generic first-party
  interceptor. Malformed or unsupported challenges and account restrictions
  retain the shared safety circuit. Controlled transport and presentation
  tests exercise this path. The packaged app's normal and invisible widgets
  returned hCaptcha's documented test token; cancellation restored the join
  modal. No live join CAPTCHA has been observed.
- Leave: one `DELETE /users/@me/guilds/{guild}` with `lurking:false`, returning
  204. `GUILD_DELETE` removes membership and navigation. `unavailable:true`
  remains an outage rather than a leave. Owners have no Leave Server menu item.
  Already-member cards navigate without an invite acceptance request.
- SakuraCord accepts onboarding invites and resumes the membership flow described
  below. Member screening and special guest/target flows remain delegated to Discord.
  Historical `GUILD_ONBOARDING_EVER_ENABLED` alone is not active onboarding.
  A late verification requirement or missing Gateway catalogue must not be
  reported as completed joining. Mutations are never automatically retried.
  Membership completion does not require a readable channel: the testing alt
  successfully left and rejoined while its server-wide View Channel permission
  was temporarily removed, then regained channel access when it was restored.

Invite cards are derived from message content even when REST `embeds` is empty
or `SUPPRESS_EMBEDS` is set. Bare `discord.gg/code`, `discord.com/invite/code`,
and `discordapp.com/invite/code` resolve; equivalent codes are deduplicated.
Inline/fenced code is excluded, while angle-bracket links still produce cards.
The V2 profile supplies `icon_hash`, `brand_color_primary`, description and
traits. Invite cards use this profile's preset gradient, or the first dominant
icon-palette color when `brand_color_primary` is null (the adaptive option).
They do not use the server banner. The gradient is radial, centered at
`(50.1%,127.05%)`, with bright/base stops at 20.65%/85.16% and CIELAB brightness
increased by 31.5 L*. The captured bundle contains a discovery-banner branch,
but this was not confirmed in live invite cards; the subsequent user-supplied
Discord captures establish the gradient header used for presentation here.
The live profile experiments covered preset colors, descriptions, traits and
missing icons; the original profile and both memberships were restored afterward.
The invite's optional `inviter` supplies the name and avatar beneath the server
name. The later Discord captures show “You sent an invite to join …” for the
current account's invite, and “{inviter} invited you to …” otherwise.

### Guild onboarding and Channels & Roles (23 September 2026)

Authenticated Computer Use and CDP captures in the unmodified Discord Official
Fresh app, exclusively in SakuraCord Testing Server, establish this baseline.
The stable desktop was `0.0.411`, client build `618874`, native build `90866`,
Electron `42.11.1`, Chromium `148.0.7778.280`, with `has_client_mods:false`.
The current asset was `web.161a57e2ae3675ed.js`, SHA-256
`859e75d4181ad0ec44005772c0da71d150c078cf83dc1704fb6cf72b4a2cb487`.
The local evidence session is `sakuracord-onboarding-20260923`; credentials,
cookies, session IDs, tokens, and installation identifiers are redacted in the
retained evidence. Both saved accounts exercised the configured questions.

Observed REST contracts, using the shared authenticated API v9 headers:

| Operation | Method and route | Body / confirmed response |
| --- | --- | --- |
| Read configuration and saved answers | `GET /guilds/{guild}/onboarding` | `guild_id`, `enabled`, `prompts`, `default_channel_ids`, **`responses`**, seen timestamp maps |
| Configure server onboarding | `PUT /guilds/{guild}/onboarding` | Partial `prompts`, `default_channel_ids`, or `enabled`; response returns normalized configuration |
| Complete initial onboarding | `POST /guilds/{guild}/onboarding-responses` | Selected IDs and seen maps; reply contains `guild_id`, `user_id`, **`onboarding_responses`** |
| Edit member answers | `PUT /guilds/{guild}/onboarding-responses` | Same shape, covering all questions including post-join questions |
| Select channels | `PATCH /users/@me/guilds/settings` | `{guilds:{guildID:{channel_overrides:{channelID:{flags:4096}}}}}`; deselection clears bit 12 |
| Show all channels | Same bulk PATCH | Partial guild `flags`; observed opt-in mode `16384` became `0` when Show All Channels was enabled |

The normal-user answer body is:

```json
{
  "onboarding_responses": ["optionID"],
  "onboarding_prompts_seen": {"promptID": 1780000000000},
  "onboarding_responses_seen": {"optionID": 1780000000000}
}
```

Timestamps are Unix milliseconds. Initial submission includes only
`in_onboarding` questions; customization includes every question. The current
asset filters removed option IDs and marks all options in the submitted question
scope seen. Prompts retain stable IDs, `type`, `required`, `single_select`, and
`in_onboarding`; options retain IDs, titles, optional descriptions and emoji
objects, `role_ids`, and `channel_ids`. The configured test server exercised
required/optional, single/multiple choice, emoji/no emoji, role/channel mappings,
post-join questions, and default channels. The current basic setup accepted one
chattable default channel; older seven-channel setup assumptions are not used.

`GUILD_MEMBER_UPDATE` confirms role replacement and onboarding membership flags.
The incomplete rejoined test member had `pending:false`, `flags:9` (rejoined +
started). Initial completion changed flags to `11` (adds completed bit 1), assigned
the selected role, and allowed a subsequently observed `MESSAGE_CREATE`.
`pending` is member screening and is independent of onboarding. Existing members
without started bit 3 are not assumed to need onboarding. `GUILD_CREATE`, READY
merged members, member chunks, and sparse member updates retain these flags.
SakuraCord uses an uncached existing Gateway member query for confirmation; a
successful answer HTTP response alone never completes the flow.

Advancing questions in Discord sent no answer mutation. Reloading before Finish
returned to the first question and discarded unsubmitted edits. SakuraCord
intentionally persists only its own unfinished choices and question position in
account-scoped draft storage. It compares membership join time and confirmed
server answers before restoring; remote changes supersede stale drafts. Question
configuration remains live and is refreshed on entry/reconnect. Initial completion
re-fetches configuration and membership; post-join writes validate against the
latest fetched configuration. Ambiguous writes use readback before rollback.

`USER_GUILD_SETTINGS_UPDATE` supplies authoritative channel overrides and guild
flags. A recorded Follow Category action used the same channel override PATCH with
the category ID and bit 12; its child controls became unavailable until the
category was unfollowed. Source inspection corroborates parent-category opt-in
inheritance and the separate FAVORITED bit; these are distinct from channel
permissions. SakuraCord ignores channel selection filtering and issues no
channel-management mutation while the global **Settings → Features → Channels → Channel customization** control is off (the default).
Server-applied default/answer channel selections are still part of Discord's
onboarding response processing. Turning local management on honors confirmed
settings; Show All Channels disables filtering without erasing individual picks.

[PR #4](https://github.com/SakuraCordApp/SakuraCord/pull/4) corroborates the three
onboarding read/response routes and bulk settings route. Its eight-hour cache,
optimistic completion assumptions, and presentation were not adopted. Pinned
Paicord corroborates guild onboarding configuration structures and member flags,
but does not supply this observed normal-user response flow. Pinned Swiftcord v1
has no guild-onboarding implementation. The public
[Guild onboarding contract](https://docs.discord.com/developers/resources/guild#guild-onboarding-object)
describes configuration; authenticated first-party traffic supplies the private
normal-user completion contract above.

Post-join customization updates immediately in the official UI. A captured burst
of five option toggles produced one final-state PUT; the pinned web source uses a
one-second debounce. SakuraCord uses that delay, serializes writes per membership,
and retains newer input when an older response arrives. A failure reads back and
rolls back only the failed version. Required questions cannot lose their final
selected answer. Selected options in dropdowns have removable chips; post-join
questions precede pre-join questions, with unseen options grouped first.

Role changes and channel settings reconcile through Gateway events. No dedicated
answer-only Gateway event was established. SakuraCord refreshes the visible editor
on foreground activation and relevant events, with a 30-second active-window
fallback. This is not instantaneous push synchronization for answer-only edits.
A three-second experimental poll hit a user-scoped 429 (`retry_after: 5.614`);
that polling interval was removed. A normal cached post-join edit now sends one
PUT without surrounding configuration/member reads.

The server menu's **Show All Channels** sends the bulk settings PATCH with guild
flags bit 14 cleared/set and preserves channel overrides. This is distinct from
the sidebar's **Show All / Hide Voice Channels**, which locally expands voice
channels and produced no settings request in the recorded interaction. The bulk
channel-selection response is an array of full guild notification settings;
SakuraCord accepts the matching confirmed entry and verifies requested bits.

### Server Guide and onboarding presentation (23–24 September 2026)

The follow-up authenticated session `sakuracord-onboarding-revision-20260923`
used the same clean stable client (web 618874, desktop 0.0.411, native 90866).
Computer Use configured and enabled a real guide in SakuraCord Testing Server;
CDP recorded redacted requests, responses, headers and Gateway frames.

| Action | Observed route | Contract |
| --- | --- | --- |
| Server profile | `GET /guilds/{guild}/profile` | Identity, member/online counts, description, brand color, traits; optional enrichment of the guide |
| Load guide | `GET /guilds/{guild}/new-member-welcome` | `guild_id`, `enabled`, `welcome_message` (`author_ids`, `message`), `new_member_actions`, `resource_channels` |
| Configure guide | `PUT /guilds/{guild}/new-member-welcome` | Full configuration; normalized response omits empty emoji objects |
| Read member progress | `GET /guilds/{guild}/new-member-actions` | `guild_id`, `user_id`, `channel_actions` keyed by channel ID with `completed` |
| Record task | `POST /guilds/{guild}/new-member-action/{channel}` | No request body; response has matching guild/member and confirmed channel actions |

The 24 September follow-up captured stable web **619060**, desktop **0.0.411**,
native **90866**, Electron **42.11.1**, with `has_client_mods: false`. READY’s
parallel `merged_members` array included the signed-in member’s `flags`,
`pending`, `joined_at`, and roles for both Testing Server and SakuraCord before
navigation. The native bootstrap now preserves those records for all guilds.
Unknown flags remain a permission-loading state and never display onboarding.

Official SakuraCord navigation had no Guide despite `GUILD_SERVER_GUIDE` being
present. Source modules 473529/978165 and the scoped READY channel/member data
establish the regular-client rule: Community + onboarding + guide capabilities,
and either unfinished home actions within seven days of joining or at least
one resource channel (`IS_GUILD_RESOURCE_CHANNEL = 128`). Testing Server had a
resource channel; SakuraCord had none and the member’s flags included 64.

The observed Guide uses welcome/tasks on the left with profile and compact
resources on the right for new members, then full resource cards beside the
profile after completion. Configured resource descriptions render on those cards
without additional history reads; opening the resource still loads its history.
The 24 September owner task POST returned confirmed completion and the member
update retired introductory tasks. Native page titles use the existing channel
toolbar; onboarding keeps the same root navigation and window chrome.

The tested task types were 0 (visit) and 1 (send a message). Task progress is
separate from onboarding completion, roles, and member screening. The app reads
progress on entry/reconnect and accepts completion only from identity-checked
server responses. Merely opening the guide does not record task completion.
Individual task progress has no established dedicated Gateway event. Completing
the last task emitted `GUILD_MEMBER_UPDATE` with flags 43 → 107, setting
`COMPLETED_HOME_ACTIONS` (64). The native guide uses that confirmed membership
flag to retire the welcome/tasks section, as the official client does. The pinned
official source also limits these introductory tasks to the first seven days
after joining. An empty progress response must not override confirmed completion.
Opening a resource card displays a side panel and does not record a task. Clicking
its corresponding visit task navigates to the channel and sends the task POST.
Resource previews requested `messages?after={channelID}&limit=5`; the opened panel
requested `messages?limit=30&around={channelID}`. Both target the oldest history.
The native resource reader pages forward from the same beginning using the
existing history provider. Unstarted native memberships returned an empty success
response; only HTTP 204 is treated as empty progress, never empty task confirmation.

Discord's question editor explicitly confirmed that **13 or more answers**
become a dropdown without descriptions. Both `type: 1` and the count boundary
are represented in the native presentation. Required onboarding replaces the
guild workspace; completed-member customization and Server Guide are scrolling
channel-list destinations. Resource pages use the existing rich message renderer
without chat identity headers or a composer.

The pinned first-party source resolves guide headers to
`/home-headers/{guild}/{hash}.png` and resource/task icons to
`/resource-channels/{channel}/{hash}` and `/new-member-actions/{channel}/{hash}`
on the CDN. Its resource navigation requests the beginning of channel history.
These source observations supplement the authenticated configuration/progress
captures; custom uploaded guide artwork was not established by the test server.
Pinned Paicord and Swiftcord contain no comparable guide progress implementation.
The official [Server Guide FAQ](https://support.discord.com/hc/en-us/articles/13497665141655-Server-Guide-FAQ)
corroborates welcome signs, tasks, and resource-channel pages.

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
| Guild and standard sticker picker, favourites, frecency, and sending | Enabled | Enabled with fixtures |

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

### Read-only account information and devices

On 18 September 2026, sanitized CDP inspection of the clean official desktop
`0.0.411`, with `web.4946991a65a94ae8.js`, observed Account and Logged-in Devices
entry issuing `GET /api/v9/auth/sessions` (HTTP 200), with no query or body.
The response is `{"user_sessions":[...]}`; entries have string `id_hash`,
ISO-8601 string `approx_last_used_time`, and `client_info` containing string
`os`, `platform`, and `location`. The first-party renderer also supports `ip`
when `location` is absent and tolerates absent client details. Other devices
are sorted by descending last-used time. No device logout was performed or
implemented.

The same bundle sources username, email, phone, and MFA from the current-user
store populated by `READY.user`, transforming `mfa_enabled` to `mfaEnabled`.
A read-only call through its existing `/users/@me` helper confirmed string
`username` and `email`, nullable `phone`, and boolean `mfa_enabled`. Public
[user documentation](https://docs.discord.com/developers/resources/user)
corroborates username, nullable email, and the MFA flag; phone and auth sessions
are private-client contracts. The pinned Paicord revision above independently
contains the same `auth/sessions` route and `UserAuthenticationSessions` shape;
pinned Swiftcord v1 and DiscordKit expose the account contact/MFA fields but
have no matching auth-session implementation. The current session matches
`READY.auth_session_id_hash` against each `id_hash`; `AUTH_SESSION_CHANGE`
updates that hash using `auth_session_id_hash`.

SakuraCord keeps this private data in provider/session memory, outside public
user models and saved-account metadata. Complete READY account details require
no HTTP read; opening Account uses `/users/@me` only if those details were
incomplete, and one `/auth/sessions` read for the count and shared devices page.
Explicit device refresh repeats that read. Sparse own-user updates preserve
omitted fields and apply explicit nulls; disconnect discards private data.
All reads use the shared metadata, scheduler, rate limits, safety circuit,
cancellation and transport retry policy. Late responses cannot publish after
session replacement. Captures retained only routes and field types, not
credentials, account values, session hashes, locations, or raw payloads.

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
| `GET /users/@me` | Incomplete-Ready compatibility fallback for a previously stored session, or explicit Account information when READY omitted private account details; no body. A newly authenticated session still fails closed if Ready omits its user. | Public user semantics and Paicord. Current official login and Swiftcord v1 obtain the authenticated user from Gateway Ready; Paicord login performs this extra read. |
| `GET /auth/sessions` | Explicit Account entry or device refresh; no query or body. Returns `user_sessions`; read-only and session-memory only. | Clean 18 September official CDP capture/renderer and pinned Paicord; S−. |
| `GET /users/@me/guilds` | Incomplete-Ready compatibility fallback only; no body. | Public guild semantics; normal current official/Paicord/Swiftcord startup uses Gateway instead. |
| `GET /guilds/{guild}/channels` | Cache-miss fallback only; no body, coalesced by guild. | Public channel semantics and all three client references. |
| `GET /guilds/{guild}/roles` | Visible role/member UI cache miss; no body, coalesced. | Public guild semantics and all three client references. |
| `GET /guilds/{guild}/roles/{role}/member-ids` | Explicit role inspection; no body; result display capped at 1,000. | Current first-party route; P−, S−. |
| `GET /users/{user}/profile` | Explicit profile; `with_mutual_guilds=true`, `with_mutual_friends=true`, `with_mutual_friends_count=true`, plus `guild_id` only in guild context; coalesced by user and guild context. A `404` for an unavailable user remains scoped to the profile presentation and does not stop the session. | Current first-party and Paicord; Swiftcord has historical profile data but no equivalent complete route. |
| `GET /collectibles-products/{product}` | Coalesced cache-miss read for a profile effect or frame returned by the profile response; query contains the current `locale`. | Current first-party route and September profile research; P−, S−. The obsolete `/user-profile-effects` fallback was removed. |
| `GET /users/{user}/profile?type=modal&with_mutual_guilds=true&with_mutual_friends=false&with_mutual_friends_count=true` | Editable current-user snapshot; append `guild_id` only for server scope. Preserve raw main and scoped field presence alongside resolved presentation. | Clean September profile-editor entry and scope selection. |
| `PATCH /users/@me` | Changed main identity fields: `global_name`, avatar data/description or `avatar_id`, `avatar_decoration_sku_id`, `nameplate_sku_id`, and the three `display_name_*` style fields. A returned credential is adopted before subsequent writes. | Clean September identity, style, history and upload actions; first-party main-profile save dispatcher. |
| `PATCH /guilds/{guild}/members/@me` | Changed server identity fields use `nick`; a nameplate is `collectibles.nameplate.sku_id`, with `collectibles.nameplate:null` for inheritance. Other identity fields use the same names as main scope. | Clean September server identity, cosmetics, inheritance and image actions. |
| `PATCH /users/%40me/profile` and `PATCH /guilds/{guild}/profile/%40me` | Changed `bio`, `pronouns`, `banner`, `accent_color`, ordered `theme_colors`, and `collectibles_sku_ids`. Preserve encoded `%40me` in these paths. | Clean September main/server metadata saves, clears and partial-save recovery. |
| `PUT /users/@me/clan` | Account-wide `identity_guild_id` and `identity_enabled`, editable from either main or server profiles; clearing sends null/false. One save reconciles the shared user and every cached profile without follow-up reads. Eligible guilds come from joined, nonpending Gateway memberships with `GUILD_TAGS` and a tag. | Clean September tag selection/removal and first-party eligibility resolver; 10 September editor-scope correction and cache-reconciliation coverage. |
| `PATCH /users/@me/settings-proto/1` | Independent custom-status update; JSON contains `settings`. Send root field 11 with the retained status settings, replacing or removing its custom-status field 2 while preserving siblings and unknown fields. Reconcile the authoritative returned settings. | Clean September status saves, clears and expiry; first-party protobuf/settings implementation. |
| `GET /collectibles-categories/v2?include_bundles=true&variants_return_style=2&skip_num_categories=0` | First collectible-picker catalogue load; retain server categories, variants and asset descriptors. | Clean September picker and catalogue requests. |
| `GET /users/@me/collectibles-purchases?variants_return_style=2` | Owned inventory, including purchase type and expiry used by selection/save gates. | Clean September inventory requests and first-party ownership resolver. |
| `GET /users/@me/avatars` | Image chooser's recent-avatar history; archived WebP thumbnails use size128 and crop sources size2048. Both append animated=true for an a_-prefixed storage hash; omitting it loses animation. | Clean September chooser and history actions. |
| `DELETE /users/@me/avatars/{avatar}` | Explicit recent-avatar removal; one attempt, expected 204. Reload history after an ambiguous result before an explicit retry. | Clean September removal of temporary test entries. |
| `GET /widget-configs/featured` and `GET /widget-configs/developer` | Add Widget catalogue; developer route only when developer mode is enabled. | Clean September widget-picker requests. |
| `GET /applications/{application}/widget-configs` | Resolve an application widget already present on a profile. | Clean September widget-resource requests. |
| `GET /users/{user}/application-identities?with_profiles=true` | Application-widget identity and display resources. | Clean September profile and widget-picker requests. |
| `GET /oauth2/tokens` | Read connection state for widget applications using repeated `application_ids`; no authorization or revocation is implied. | Clean September widget connection-state requests. |
| `GET /users/@me/widgets/suggested-games` | Server-supplied game suggestion feeds, combined with the versioned first-party fallback policy. | Clean September game-widget picker and source policy. |
| `GET /games` | Resolve game IDs with repeated ordered `game_ids`, retaining metadata needed by widgets and game details. | Clean September suggestion, search, widget and game-detail requests. |
| `GET /games/autocomplete?q={query}` | Explicit nonempty game search, first-party normalization and debounce; cache only the matching query's result. | Clean September game search and first-party autocomplete source. |
| `GET /content-inventory/users/@me/similar-games/{game}` | Similar games for an opened game detail. | Clean September game-detail flow. |
| `GET /games/{game}/announcements?limit=8` | Announcements for an opened game detail. | Clean September game-detail flow. |
| `POST /users/@me/widgets/assets/upload` | Allocate a widget image with its exact `filename` and `file_size`; PUT the bytes to the validated returned storage URL without Discord account credentials. | Clean September cover/field image uploads. |
| `PUT /users/@me/widgets` | Complete ordered `widgets` list; retain existing IDs, omit IDs for new entries, preserve unknown originals, and encode pending/stored image references distinctly. | Clean September widget edits, reordering, removals and image saves. |
| `GET /guilds/{guild}/emojis` | Stale/missing Gateway and disk-cache fallback; no body, coalesced. | Public emoji semantics and all three client references. |
| `GET /users/@me/settings-proto/2` | Explicit emoji-, GIF-, or sticker-settings cache miss; no body, coalesced for the provider session. Sticker favourites come from ordered packed fixed64 IDs in top-level field 3; sticker frecency comes from the field-4 map. | Current first-party clean-client actions and Paicord's generated Frecency settings schema; Swiftcord has the versioned settings-proto path but no complete expression picker. |
| `PATCH /users/@me/settings-proto/2` | One explicit emoji, GIF, or sticker favourite add/remove, or a delayed sticker-frecency flush. JSON contains only `settings`; emoji/GIF mutations carry the complete updated base64 Frecency proto, while sticker mutations carry only changed fields and consume the complete merged proto returned by the server. An empty sticker-favourites list is encoded as the exact two-byte empty field 3. A sticker favourite action includes dirty field 4 when present; ordinary sends debounce that field rather than synchronously coupling the settings mutation to the message POST. A sticker-use update rewrites only the selected field-4 map entry, preserving all other entries byte-for-byte and retaining unknown fields on the selected entry. Emoji favourites are ordered, deduplicated repeated strings in field 5 and capped by the first-party client at 250. The GIF favourite map key is the canonical GIF URL; its value contains format (`IMAGE = 1`, `VIDEO = 2`), source URL, width, height, and monotonically increasing order, displayed descending by order. The declared format is preserved on reads, including extensionless CDN sources. Unrelated and unknown top-level proto fields are preserved. | Sanitized first-party sticker/favourite/frecency actions and SakuraCord rejection diagnosis on 3 September 2026, current first-party emoji/GIF actions, and generated Paicord schema; Swiftcord v1 has no corresponding complete favourite mutation. |
| `GET /sticker-packs?locale={locale}` | First sticker-picker open in a provider session; returns Discord standard packs and their ordered sticker catalogues. The response and media are session-cached. | Sanitized current first-party clean-client reload/open on 3 September 2026; P−, S−. |
| `GET /gifs/trending?locale={locale}&media_format=webm` | Opening the GIF picker; one cacheable landing read returning the current base categories in server order and their preview media. | Current first-party route and clean-client request; P−, S−. |
| `GET /gifs/trending-gifs?media_format=webm&locale={locale}` | Explicit Trending GIFs selection; no body. The returned order is preserved. | Current first-party route and clean-client request; P−, S−. |
| `GET /gifs/search?q={query}&media_format=webm&locale={locale}` | Nonempty picker search after the current 250 ms debounce; no speculative or paginated follow-up. The live default response is 50 results and its order is preserved. | Current first-party route/action and clean-client `hello` request; P−, S−. |
| `POST /gifs/select` | Profile-image GIF selection only; `id` plus query `q`, empty for Trending. Independent one-attempt notification after starting the editable image fetch; does not gate image selection. | Clean September profile-image selection and first-party picker actions; P−, S−. |
| `GET /channels/{channel}/messages` | Visible history and explicit reaction intents whose target is absent from the provider working set; the latter reads `around={message}&limit=1` before deciding whether a mutation is needed (see reaction rules below). Guild history requires effective `VIEW_CHANNEL` and `READ_MESSAGE_HISTORY`, and voice-channel history additionally requires `CONNECT`. The current clean client uses `limit=10` for a newly selected uncached channel, which SakuraCord matches once per channel per uninterrupted Gateway connection. A dispatched newest-page read is allowed to finish and populate the session stores after a later selection supersedes its presentation; rapid navigation does not abort those reads. Reopening a loaded newest-backed channel restores its bounded session-memory page and sends no history request. After a Gateway gap, the retained page is presented immediately but its completeness marker is invalidated; returning to Ready refreshes the selected page once and later reopened pages refresh once on selection. Distant navigation uses `around={message}&limit=50` as a replacement window; its older and newer edges paginate independently with `before={oldest}&limit=20` and `after={newest}&limit=20`. A historical window is not cached as though it were newest-backed. No body. | Public message semantics and `before`/`after`/`around` pagination, current first-party permission/message paths and stale-connection refresh, and Paicord's permission-checked channel store. Swiftcord v1 checks `VIEW_CHANNEL` before presentation but otherwise supplies only a historical unguarded/refetching history path. Paicord retains a per-channel in-memory store and uses a historical 50-message initial page. The current first-party cache behavior and connection-generation invalidation take precedence. |
| `GET /channels/{channel}/messages/pins` | Opening or paginating native pins; `limit=25` and optional ISO-8601 `before` equal to the last returned `pinned_at`. Response items carry `pinned_at` plus the complete message and are presented newest-pin first. Reads require `VIEW_CHANNEL`; without `READ_MESSAGE_HISTORY` Discord returns no pins. Safe-read cancellation, one confirmed transport recovery, central rate limiting, diagnostics, and session ownership match history reads. | Sanitized clean desktop empty, 25-item, and one-item second-page requests on 30 August 2026 plus current public message and permission documentation for the 1–50 limit and access behavior. |
| `PUT` or `DELETE /channels/{channel}/messages/pins/{message}` | One explicit Pin or Unpin action, empty body, guarded by effective `PIN_MESSAGES` (`1 << 51`). The local message and open pins surface update optimistically; one mutation per message is in flight, later conflicting intent waits for it, definite 4xx failure rolls back, and ambiguous failure is not replayed. | Sanitized clean desktop PUT/DELETE requests and HTTP 204 responses on 30 August 2026, current public message endpoint, and 23 February 2026 permission change log. Live Gateway samples corroborated `pinned:true`/`false`, channel-pin invalidation, null final-pin timestamp, and independent pinned-message deletion. |
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
| `POST /channels/{channel}/messages` | One explicit send; `content`, nonce, `tts:false`, `flags:0`, macOS `mobile_network_type:"unknown"`, optional reply/attachments, and `X-Context-Properties` location `chat_input`. A reply with its author notification enabled omits `allowed_mentions`; disabling it adds `parse:["users","roles","everyone"]` and `replied_user:false`. SakuraCord deliberately adds `enforce_nonce:true` to ordinary composer sends. A poll send instead uses the exact `poll` payload and `poll_creation` context described under Polls, with empty content and no `enforce_nonce`. A native sticker-only send instead has empty `content`, one-element `sticker_ids`, and omits `enforce_nonce`; it cannot be combined with uploaded attachments. Standard, same-guild, and entitled cross-guild stickers use this route. An unentitled cross-guild custom sticker uses the existing attachment reservation/upload path with the rendered WebP and never also sends the native sticker. An explicit forward uses the same route once per selected destination (maximum five), empty `content`, nonce without `enforce_nonce`, `message_reference` with `type:1` and source IDs, and context location `forwarding`. Selected forwards start together and settle independently. Optional user-entered context is one later ordinary send per successful destination unless slowmode without bypass forbids it. Picker browsing and typing perform no HTTP or Gateway search. | Current first-party build and clean macOS CDP request/search/sticker-send observation through 3 September 2026. Pinned Paicord has no forward or complete sticker picker request; Swiftcord v1 corroborates ordinary reply mention control but has no comparable current picker. DiscordKit's later DTO-only snapshot support is decoding evidence, not request or picker evidence. |
| `POST /channels/{channel}/attachments` | Explicit files only; `files` entries contain string index `id`, `filename`, `file_size`, and `is_clip:false`. | Current first-party upload action and Paicord; Swiftcord has no comparable presigned upload. |
| `PUT {Discord-issued upload_url}` | One unauthenticated storage PUT per reserved file, `application/octet-stream`, raw bytes, no Discord authorization metadata. | Current first-party and Paicord; S−. |
| `PUT /channels/{channel}/polls/{message}/answers/@me` | Explicit poll vote, replacement, or removal; `answer_ids` is a string array, empty to remove. HTTP 204; no automatic mutation retry. | Two fresh authenticated desktop captures, 19 September 2026; see Polls. |
| `GET /channels/{channel}/polls/{message}/answers/{answer}` | Visible voter popover; `limit=100&type=2`, optional `after` user ID; response `users`. | Fresh official voter-modal capture and public pagination contract, 19 September 2026. |
| `POST /channels/{channel}/polls/{message}/expire` | Explicit author action on an active poll; no body; returns the updated message. | Fresh official ending capture and native cross-client verification, 19 September 2026. |
| `PATCH` or `DELETE /channels/{channel}/messages/{message}` | Explicit edit with only `content`, or explicit deletion with no body. | Public message semantics and all three references. |
| `PUT` or `DELETE /channels/{channel}/messages/{message}/reactions/{emoji}/@me` | One coalesced explicit reaction intent; empty body. A working-set miss first performs the history GET with `around={message}&limit=1`; a failed or missing-target read prevents mutation, and an already-satisfied intent sends no mutation. | Public reaction semantics and all three references. Cache-miss sequencing is a SakuraCord policy verified by `ProviderRequestContractTests` and the public message pagination contract on 5 September 2026, not a new clean-client observation. |
| `GET /channels/{channel}/messages/{message}/reactions/{emoji}` | Visible reactor preview only; `type=0&limit=5`, no pagination. | Public reaction-user semantics and current first-party; Paicord/Swiftcord provide historical reaction reads. |
| `GET /channels/{dm}/call` | One-to-one explicit call start readiness read only; no body. | Current first-party; P−, S− for the current readiness contract. |
| `POST /channels/{dm}/call/ring` | Explicit call start after pushed call creation; `recipients:null` or the explicit recipient list. | Current first-party; Paicord partial, S−. |
| `POST /channels/{dm}/call/stop-ringing` | Explicit decline; nonempty `recipients` list. | Current first-party; Paicord partial, S−. |

The first-party asset also defines `/gifs/select`, `/gifs/suggest`, and
`/gifs/trending-search`. They are not required for picker content, search,
favourite persistence, or message sending and SakuraCord's message picker does
not issue those analytics/suggestion requests. Profile-image selection uses
the separately audited `/gifs/select` notification above. A message-picker open creates the landing
read and the shared settings read only. Search and trending each create one
GET, and each favourite action creates one non-retried PATCH.

### Upload metadata privacy

The enabled-by-default Privacy setting **Remove metadata from images and videos**
prepares local media copies before Discord attachment/widget reservations and
before Catbox/Litterbox multipart construction. Reservation sizes use the prepared
bytes. Attachment selection warns when sanitation fails, offering Attach Anyway
or Cancel. Approval covers that file’s exact bytes, verified by SHA-256; uploads
use a stable private copy. Changing the file or resetting the account invalidates
approval. A later failure or changed file is confirmed again before uploading. Disabling the setting bypasses this
preparation. Compaction remains independent and may itself discard metadata.

Discord publicly documents EXIF removal in its
[image pipeline](https://discord.com/blog/modern-image-formats-at-discord-supporting-webp-and-avif).
The first-party client and backend both participate in tested image paths, as
reported in the [2025 forensic study](https://artsandmedia.ucdenver.edu/docs/librariesprovider27/alma-mater/nash_thesis_fall2025.pdf)
(pp. 42–44). This establishes the EXIF privacy behavior, not a guarantee for every
Discord client, file type or external host. SakuraCord deliberately sanitizes
locally unless the user explicitly approves uploading the original.

JPEG uses ImageIO's lossless metadata rewrite; PNG/APNG, GIF, WebP and HEIF/AVIF
use container edits because native copying retains some metadata or is unsupported.
HEIF EXIF/XMP item extents are overwritten, including old private bytes, without
moving image extents. Container-level XMP UUID/XML boxes and padding are cleared
in place; unrecognized container boxes and duplicate metadata roots fail closed.
TIFF rebuilds from full-depth pixels because native metadata
copying leaves unreferenced private bytes. Orientation and colour profiles remain.
AVFoundation passthrough movie export preserves video/audio/subtitle track groups,
languages and playback defaults, with empty movie and track metadata and the
sharing metadata filter; timed metadata tracks are omitted. Unsupported/corrupt
media require explicit approval to upload unchanged. Documents, archives and
standalone audio are outside this image/video policy. This is tested with synthetic
GPS/author metadata and intercepted upload requests, without live uploads.

### Attachment selection and external-host fallback

Before an attachment enters a composer, SakuraCord applies Discord's current
per-file account cap using binary byte counts: 20 MiB for a base account,
50 MiB for Nitro Basic or legacy Nitro Classic, and 500 MiB for Nitro. Selection
uses the privacy-prepared copy's byte count, while retaining the original file
for the draft and any compaction or external-host fallback. A prepared file
at the exact boundary is accepted. A larger file is rejected during selection,
before `/channels/{channel}/attachments` can be reserved; the provider repeats
the check as a fail-closed guard.

Discord's public
[file-attachments FAQ](https://support.discord.com/hc/en-us/articles/25444343291031-File-Attachments-FAQ)
documents the August 2026 advertised base-limit increase from 10 MB to 20 MB. The
remaining tier mapping is supported by the public
[user resource](https://docs.discord.com/developers/resources/user)
premium-type values and the 5 August 2026 production web asset
`web.d96787f461ff77e9.js` (SHA-256
`216e7f6ce5c61983a33254229f76773984545f0a35402dca7c3376176573215e`).
That asset maps premium types 1 and 3 to `0x3200000` and type 2 to
`524288000`, and rejects only when `file.size > maximum`. Paicord revision
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
Discord client metadata. Upload requires a named host choice in the size warning
or the user’s saved Automatically policy and selected external provider in General
settings. Ask remains the default; Never skips external uploads. Local compaction
is attempted first according to its separate policy, only for oversized files.
Success adds the returned URL to the same draft for
review; it never sends a Discord message. Cancellation or failure performs no
Discord mutation. Catbox's documented blocked executable and document
extensions are rejected locally. The implementation was cross-checked against
Equicord's GPL-licensed
[`FileUpload` plugin](https://github.com/Equicord/Equicord/tree/main/src/equicordplugins/fileUpload)
for behavior only and independently implemented against Catbox's official
[tools/API documentation](https://catbox.moe/tools.php),
[service limits](https://catbox.moe/), and [FAQ](https://catbox.moe/faq.php).

### Message and draft translation (third-party, user-initiated)

Translation is off by default. After the user chooses a provider in Features
settings, choosing **Translate Message** or **Translate Draft** sends only that
text and the chosen target language:

| Endpoint | Body | Result handling |
| --- | --- | --- |
| `POST https://api-free.deepl.com/v2/translate` (keys ending in `:fx`) or `POST https://api.deepl.com/v2/translate` | JSON `{"text":[text],"target_lang":code}` with `Authorization: DeepL-Auth-Key`. | `translations[0].text` and `detected_source_language`; HTTP 403 is a rejected key and 456 an exhausted quota. |
| `POST <server>/translate` (LibreTranslate; default `http://127.0.0.1:5000`) | JSON `{"q","source":"auto","target","format":"text"}`, plus `api_key` only when one is saved. | `translatedText` and `detectedLanguage.language`; an `error` field is shown to the user. |

Requests use an ephemeral, cookie-free session with a 20-second timeout and never
carry a Discord credential, cookie, or client metadata. Mentions, custom emoji,
timestamps, command mentions, links, and code are replaced with private-use
placeholders before sending and restored afterwards; a draft whose placeholders
do not return intact is left unchanged. Slash-command drafts are refused.
Results stay in memory: message translations are shown below the original only
while its content is unchanged, and a translated draft is ordinary composer text
the user reviews and sends. API keys live in the Keychain under their own service
and are never exported. LibreTranslate servers must use HTTPS unless they are on
the local network (loopback, `.local`, unqualified, or private addresses), which
the app's App Transport Security local-networking exception allows. The request
and placeholder behavior was cross-checked against the GPL-licensed
[Concord](https://github.com/chojs23/concord) client for behavior only, and
implemented against DeepL's [API reference](https://developers.deepl.com/docs/api-reference/translate)
and LibreTranslate's [API documentation](https://docs.libretranslate.com/guides/api_usage/).

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
| User-completed login or server-join CAPTCHA | At most 1 replay of the challenged request, only after human completion; a second challenge ends the attempt. |

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
Supported invite hCaptcha responses use the bounded human-completion exception
described above. Ordinary resource-scoped permission failures remain scoped when the decoded
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
ETF Ready payload. The compressed-input bound remains 8 MiB. The per-message
decompressed bound is 64 MiB: account bootstrap data exceeded the former
16 MiB limit in a sanitized 20 September 2026 support export. This is a
SakuraCord resource bound, not a Discord protocol maximum. It also applies to
fresh READY after reconnect and to uncompressed text messages. The decoder
stops before appending bytes beyond the bound, reports scalar observed/limit
byte counts, and preserves the size failure through bootstrap instead of
misreporting it as a remote disconnect. It never retries a rejected payload in
a reconnect loop. The shared zstd context and per-message output draining are
unchanged.

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

Current first-party Identify normally uses capability bitfield `1734653` and
conditionally adds bit 15 (`1767421`) only when its
`private_channel_obfuscation` experiment enables channel obfuscation. The
current web bundle selects that bit at Gateway connection time and implements
the corresponding guild-channel integrity and resynchronization protocol.
SakuraCord advertises `1734653`: it does not implement that experimental
protocol, and requesting it causes Discord to replace inaccessible guild
channel names with the `__hidden__` sentinel. Its Ready Supplemental decoder
still accepts `lazy_private_channels` when Discord supplies them and hydrates
their recipients through the shared user table. Discord's public Gateway
documentation does not define user-client capability bit 15. Pinned Paicord
declares capability bits only through 14 and 16 and leaves `ReadySupplemental`
empty; pinned Swiftcord v1 has no corresponding capability or supplemental
implementation.

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
- `USER_UPDATE` and `GUILD_MEMBER_UPDATE` also invalidate full profile data,
  matching `UserProfileStore` in public asset `web.831e884588cb7b8b.js`, checked
  on 10 September 2026. Invalidation prevents older in-flight reads from
  publishing and adds no request by itself. A visible, clean profile editor
  performs one modal-profile refresh while retaining its preview; dirty drafts
  defer the refresh. Returning to the app also refreshes that visible editor.
  An authenticated clean-client capture added and immediately removed one
  temporary personal widget through the ordinary ordered-list PUT (both 200),
  restoring the original widget records exactly. Neither operation dispatched
  `USER_UPDATE` or `GUILD_MEMBER_UPDATE` in that connected client. The bundle's
  `WIDGET_PENDING_SAVE_SUCCESS` is a local action applying the PUT response,
  not an inbound Gateway event. Foreground refresh therefore covers widget
  changes made in another client without introducing periodic profile polling.
  Pinned Swiftcord v1 and Paicord's current-user store provide no separate
  personal-widget Gateway update contract.
- `MESSAGE_DELETE_BULK` removes every named loaded message and publishes the
  same per-message deletion boundary as a single delete.
  `CHANNEL_PINS_UPDATE` carries the channel and optional last-pin timestamp; it
  invalidates only that channel's pin page, and an open matching page performs
  one paginated-pin refresh. It is not a substitute for `MESSAGE_DELETE`, which
  independently removes a deleted pinned row. `THREAD_MEMBERS_UPDATE`,
  `VOICE_CHANNEL_STATUS_UPDATE`, and `VOICE_CHANNEL_START_TIME_UPDATE` update
  their cached channel or thread fields in place. Voice start times accept the
  documented Unix-seconds representation; ISO timestamps remain a lossless
  compatibility input for first-party-normalized channel objects.
- A `RATE_LIMITED` dispatch records Discord's `retry_after` seconds against
  the rejected outgoing opcode. A send attempted during that cooldown fails
  locally, and a rejected member request completes its pending continuation
  with an error. SakuraCord does not replay, retry early, or speculate about a
  replacement Gateway request.
- `USER_SETTINGS_PROTO_UPDATE` type 2 reconciles emoji favourites and sticker
  favourites/frecency immediately.
  A full event replaces the cached Frecency-and-Favourites proto. A partial
  event replaces only the top-level fields present in its proto and preserves
  every omitted and unknown field before publishing the decoded account
  expression settings. This matches the first-party store's `mergePartial` path in public
  web asset `web.e3526df05a0a7718.js`, rechecked on 29 August 2026, and creates
  no follow-up request once the settings cache is loaded.
- Soundboard, scheduled-event and exception, Stage,
  integration, webhook, AutoMod, entitlement, and subscription dispatches have
  no production state consumer. They are deliberately ignored after sanitized
  transport diagnostics instead of occupying the application event stream or
  maintaining unused caches. They do not enable an unsupported feature, add
  fan-out, or trigger an authenticated read.
- Ready and `GUILD_CREATE` guild objects seed their complete usable sticker
  catalogues. `GUILD_STICKERS_UPDATE` replaces only the named guild catalogue
  and publishes one local update without a compensating REST request.

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
- for each explicitly started or watched screen-sharing stream, a separate Voice v8
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
- profile-image GIF cropping applies the provider-specific first-party proxy
  paths described above. It uses the same unauthenticated, cookie-free media
  queue; authenticated selection notification remains on the shared REST
  transport. Proxy mapping does not apply to ordinary picker thumbnails.

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

Explicit import from the local stable Discord desktop client reuses the same
pending-credential Gateway path without replaying login or issuing a pre-Gateway
`GET /users/@me`. The local account ID is only a selection constraint: persistence
requires an exact match with the authoritative `READY.user` ID. It introduces no
new Discord endpoint. The source-storage and macOS authorization boundary is
documented in [Authentication and persistence](ARCHITECTURE.md#authentication-and-persistence).

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
- Slowmode uses each channel or thread's `rate_limit_per_user`; thread messages
  inherit permissions from their parent but use the thread's own interval.
  Current immunity is `BYPASS_SLOWMODE` (`1 << 52`), including owner and
  administrator permission resolution, plus bots. Manage Messages, Manage
  Channels, and Manage Threads alone no longer bypass slowmode, per Discord's
  [February 2026 permission split](https://docs.discord.com/developers/change-log#permission-changes-going-into-effect-february-2026-for-pin_messages-bypass_slowmode-create_guild_expressions-and-create_events).
  SakuraCord deliberately starts its local countdown on confirmation, not upload
  start. The first REST or own-user Gateway message confirmation starts it;
  duplicate confirmations do not restart it. Recent confirmed history can seed
  a reopened session without persisting Discord messages or cooldowns. Discord
  error `20016` returns its `retry_after` to the composer without replaying the
  mutation or treating slowmode as a generic REST bucket delay. These semantics
  were checked against public documentation on 7 September 2026 and the retained
  4 September production asset `web.f803cc09a978437c.js`, whose slowmode store
  separates message and thread-creation cooldowns. The pinned Paicord model
  retains the channel interval; its app and pinned Swiftcord v1 have no comparable
  local slowmode controller. No new outbound request shape is introduced.
- Native sticker sends enter the same nonce-keyed optimistic outbox as ordinary
  messages. Picker dismissal and timeline insertion do not wait for REST; the
  selected sticker's loaded media identity remains attached to the row through
  confirmation. Definite failures become retryable failed rows, while ambiguous
  timeouts remain pending for Gateway reconciliation.
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
- Pin pages remain account- and channel-scoped session memory. The `pinned`
  field is retained through history, search, complete Gateway messages, and
  omitted-field partial updates. A `CHANNEL_PINS_UPDATE` invalidates only its
  named channel and refreshes an open matching pin page once. A Gateway message
  update reconciles an optimistic mutation without applying it twice.
  `MESSAGE_DELETE` removes the deleted item directly because Discord explicitly
  does not send `CHANNEL_PINS_UPDATE` when a pinned message is deleted.

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
  When the provider's bounded working set lacks the target, the intent first
  performs `GET /channels/{channel}/messages?around={message}&limit=1`, without
  a body or further history pagination. Normally this adds one GET before at
  most one PUT/DELETE; the GET retains the transport's two-attempt read budget
  for eligible recovery/rate-limit handling. Cached targets require no GET.
  Failure of the read or absence of the exact target (including an undecodable
  target) fails the intent and rolls back its optimistic state without a
  mutation. A successful read that already satisfies the desired state also
  sends no mutation. Returned messages repopulate the bounded provider working
  set and use normal history identity/alias learning and member hydration;
  missing guild members may use the existing Gateway member-resolution path.
  The read does not replace or paginate the app's visible history window.
  Evidence: the cache-miss fixture in `ProviderRequestContractTests` checks one
  `around=350&limit=1` read before a single PUT; code review on 5 September 2026
  covers failure/no-op behavior and cache effects. Discord's public
  [Get Channel Messages contract](https://docs.discord.com/developers/resources/message#get-channel-messages)
  confirms `around` and the permitted limit range. This fallback is SakuraCord
  cache-reconciliation policy, not an observed additional clean-client request.
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

### Polls

Polls were audited on 19 September 2026 using two independent authenticated CDP
captures from the clean official macOS client `0.0.411` (`com.hnc.Discord`),
Electron `42.11.1`, Chromium `148.0.7778.280`, API/Gateway v9 with ETF and
zstd-stream. The loaded main asset was `web.d793fc00a2d44795.js`, SHA-256
`da9effbe3d25465ff33a7ccce81232c9aa47cafc85247daa49c651464d45c522`, build ID
`2ae1bc1225ba4bf504c4d700814c349182721466`. Explicitly authorized creation,
voting, replacement/removal, voter inspection, and ending used only the private
testing server. Both accounts and both clients exercised the same polls.

Creation uses the ordinary message POST with empty `content`, nonce, `tts:false`,
`flags:0`, `mobile_network_type:"unknown"`, and `poll`; it omits `enforce_nonce`
and uses context location `poll_creation`. The poll contains `question.text`,
`answers:[{poll_media:{text,emoji?}}]`, integer-hour `duration`,
`allow_multiselect`, and `layout_type:1`. Answer IDs are assigned by Discord.
Unicode emoji send `name`; custom emoji send string `id` and empty `name`.
The current desktop UI requires question text up to 300 UTF-16 units and 2–10
nonempty answer texts up to 55 units. It trims text, omits blank answer rows,
rejects emoji-only answers, and offers 1, 4, 8, 24, 72, 168, or 336 hours.
Creation requires sending permission and `SEND_POLLS` (bit 49) in guild channels.
The shared emoji eligibility/picker handles account and guild restrictions.

Voting replaces the complete selection with `PUT .../polls/{message}/answers/@me`
and `answer_ids` containing **strings**, including an empty array to remove all
votes; the observed response is 204. The desktop presents Remove Vote followed
by a new selection, rather than editing a submitted selection in place. Poll
questions, answers, emoji, multiselect mode, and duration have no post-creation
edit action in the audited client. SakuraCord excludes poll messages from all
message-edit entry points. Only the author may explicitly end an active poll.

The voter list uses `GET .../polls/{message}/answers/{answer}?limit=100&type=2`,
with `after` for subsequent pages and `users` in the response. The first-party
hover preview separately uses `limit=3&type=2`; SakuraCord's voter popover uses
the full-list route. A 100-user response permits another page. Reads retain the
shared safe-read, cancellation, rate-limit, and account-session rules; poll
mutations are never automatically replayed after an ambiguous failure.
Expected HTTP 400 poll failures remain local to their operation: voting blocked
or expired (`520000`/`520001`), expiration of an expired or non-poll message
(`520001`/`520006`), and poll creation with an unavailable channel type or emoji
(`520002`/`520004`). These route-scoped exceptions use Discord's
[documented error codes](https://docs.discord.com/developers/topics/opcodes-and-status-codes),
checked on 21 September 2026 and covered by local transport fixtures; they are
not additional live captures. Authentication/account restrictions, challenges,
and malformed requests retain the shared safety stops.
Known zero-vote answers display an empty voter list without issuing a GET.

`MESSAGE_POLL_VOTE_ADD` and `MESSAGE_POLL_VOTE_REMOVE` carry channel, message,
user, guild, and integer answer IDs. Ordered patches update all retained message
projections, including when the provider's bounded cache has evicted a message.
Current-user duplicate notifications are idempotent. The current renderer also
handles `MESSAGE_POLL_VOTE_ADD_MANY` with `votes:[{answer_id,users:[userID]}]`;
this batch shape was verified in the fresh first-party source, not observed as
a live dispatch. A new poll's creation event omits results and starts empty;
historical missing results remain unknown rather than becoming zero votes.

Ending sends an empty-body `POST .../polls/{message}/expire`, returning a message.
The observed Gateway sequence supplies an expired poll without results, then
final answer counts and `is_finalized:true`, and a type-46 closing message with
a `poll_result` embed. The final broadcast's `me_voted:false` values are not
personalized; reconciliation preserves existing personal selections. Late REST
responses and omitted results cannot overwrite a finalized tally. Summary fields
include `poll_question_text`, `victor_answer_votes`, and `total_votes`; a unique
winner additionally supplies `victor_answer_id` and `victor_answer_text`. Ties
and zero-vote polls omit those winner fields.
Natural expiry was also observed in both clients: the local deadline revealed
results, followed by the final Gateway tally and closing message without an
expiry request.

Results stay hidden until the user votes, explicitly reveals them, or the poll
closes. Removing one's vote hides them again. Percentages round each answer's
count divided by total **selections**, including in multiselect polls. Visible
result changes use the native timeline's display link and bounded drawing;
hidden results never animate into view. The expiry clock is local and sends no
request. Only an explicit reveal/vote on an unknown historical tally may load
that one message through the existing history route.

Discord's public poll resource and pinned Paicord
`694761c1938b73bb60bd58942674dfe73aab1135` corroborate the model and permission
boundaries. Pinned Swiftcord v1 has no comparable poll implementation. Recent
DiscordKit `58cf0949336d3d1652ba09e8f65cfc6df098fef4` was inspected as a model
and endpoint reference; its integer vote payload does not override the fresh
string-ID desktop capture. No new networking dependency was added.

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

### Inbox

Unread and Mentions were checked with authenticated REST and Gateway CDP
captures of the clean official Discord desktop on 20 September 2026. Both
saved accounts exercised disposable content in one dedicated test server.
The loaded Inbox asset was `b7061492a30fc3b9.js`; the main asset was
`web.d793fc00a2d44795.js`. DiscordKit revision
`58cf0949336d3d1652ba09e8f65cfc6df098fef4` was an additional reference;
first-party traffic determines the undocumented user-client contracts.

- Mentions use `GET /users/@me/mentions` with `limit=25`, `roles`, `everyone`,
  optional `guild_id`, and an exclusive `before` cursor from the last raw
  response entry. Dismissal uses `DELETE /users/@me/mentions/{message_id}`
  and `RECENT_MENTION_DELETE`. It does not acknowledge a channel or clear
  its mention badge. Read acknowledgements do not remove recent mentions.
- Unread freezes group order and message boundaries when opened/refreshed.
  Priority sorting is stable over the server-rail order, with selectable
  channels ordered by channel position (not category position) and joined
  threads immediately after their parent. Read-state flag `4` places
  low-importance mentions after other mentions.
  Normal groups display up to 25 messages after the old read boundary;
  fetching around that boundary and paging forward uses ordinary history
  routes. New arrivals do not append to the frozen message range. Edits and
  deletions reconcile in place. Forum groups show active posts newer than
  the old forum boundary in ascending ID order and accept live catalogue
  updates. Restricted groups require local server consent before expansion;
  Mentions hide their accessories until consent and omit restricted messages
  for accounts that cannot view adult content.
- Mark Read acknowledges the captured newest boundary. Undo uses an ordinary
  channel ACK with the old boundary, retaining `last_viewed` and omitting
  `manual` and `mention_count`; it does not restore the old mention count.
  A newer-version Gateway ACK can therefore move a read boundary backward.
  Fully loaded, expanded empty groups acknowledge and disappear without Undo.
  Bulk Inbox reads use frozen targets in `/read-states/ack-bulk` batches.
- Scheduled-event groups have read-state type `1`, a guild resource ID,
  `last_acked_id`, and `badge_count` in READY. Their individual ACK is
  `POST /guilds/{guild_id}/ack/1/{event_id}` with `{}`, reconciled through
  `GUILD_FEATURE_ACK`. Undo of a fully acknowledged event group restores its
  card locally without sending an ACK. Event interests use
  `GET /users/@me/scheduled-events?guild_ids={guild_id}` and
  `PUT`/`DELETE /guilds/{guild_id}/scheduled-events/{event_id}/users/@me`;
  the PUT body is `{"response":1}`. Event and RSVP Gateway dispatches update
  the same cached entries.
- Tab and collapsed-group settings patch `/users/@me/settings-proto/1`,
  preserving unknown protobuf fields. Event collapse uses Discord's reserved
  channel key within each guild's settings map; guild identity must remain
  part of that key. Mention filter choices persist locally across sessions
  and account switches; they are not server settings.

Bookmarks and Reminders are outside this Inbox implementation.

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
- A fresh Ready after a rejected Resume publishes a complete replacement
  workspace through the existing snapshot event before the connection becomes
  ready. It replaces channel membership and notification settings and merges
  versioned read state without resetting pending acknowledgements or their
  token. Successful Resume continues to use Gateway event replay. Snapshot
  assembly is shared with initial bootstrap and adds no REST requests.
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

### Screen sharing

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

UDP transport readiness fails after three seconds. IP discovery retries its
74-byte request twice at one-second intervals and likewise fails after three
seconds without a response. These bounds prevent a lost discovery datagram or
stalled provisional socket from leaving the UI connecting indefinitely; failed
setup closes the provisional transport instead of retaining an unfinished
socket.

Voice WebSocket recovery follows Discord's published close-code contract.
Timed-out (`4009`) connections identify again instead of attempting to resume.
Session-invalid (`4006`) and server-directed disconnects (`4014`, `4021`, and
`4022`) tear down only SakuraCord's local media session and do not publish a
main-Gateway leave, so another client that took ownership of the account's
voice session is not disconnected in turn. A sanitized 2 September displacement
capture confirmed that Discord first replaces the account's main-Gateway voice
session ID, then closes the displaced Voice WebSocket with `4006`; identifying
again with that socket's stale session ID repeats `4006` indefinitely. Other
transient closures retain the bounded resume path.

A sanitized authenticated 23 August source-quality follow-up confirmed that
the stream Voice Identify keeps `streams[0].type:"screen"`, while its later
opcode-12 media advertisement uses `streams[0].type:"video"`. Source quality
advertises `max_resolution` as `type:"source"`, `width:0`, and `height:0`, while
retaining the captured pixel dimensions in the encoder itself. Explicit
resolution qualities use `type:"fixed"` with their actual encoded width and
height. The observed Source/60 advertisement also retained RID and quality 100,
`max_framerate:60`, and `max_bitrate:9000000`.

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
  `video:true`, and a `screen` RID. A broadcaster advertises the media stream as
  `video` with Voice opcode 12; Source quality uses the semantic zero-dimension
  `source` resolution above rather than exposing its captured height as a fixed
  quality label. A viewer requests the chosen SSRC at quality 100 with Voice
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

### Soundboard

The soundboard contract was authenticated and dynamically rechecked against a
clean first-party desktop client on 31 August 2026, then statically rechecked
against the current public web client on 1 September 2026. The bounded live
actions were performed only in the designated private test guild and voice
channel. Identifiers, credentials, complete settings blobs, and user content
are not retained in this baseline.

- `GET /soundboard-default-sounds` returns the six Discord defaults. Defaults
  have no source guild and always use native delivery. Their media, like custom
  sound media, is read from
  `https://cdn.discordapp.com/soundboard-sounds/{sound_id}`. Local preview is
  only a CDN read and emits neither a REST mutation nor a Gateway send.
- Guild catalogs are requested on the main Gateway with opcode 31 and a
  bounded, deduplicated `guild_ids` array. Each `SOUNDBOARD_SOUNDS` dispatch is
  authoritative for its guild. `GUILD_SOUNDBOARD_SOUND_CREATE`, `_UPDATE`, and
  `_DELETE` reconcile the cached catalog without a REST fallback. Requests
  time out and fail closed; they are not replayed indefinitely.
- Native playback performs one
  `POST /channels/{channel}/send-soundboard-sound`. The JSON body contains
  `sound_id`, nullable `emoji_id`, nullable `emoji_name`, and
  `source_guild_id` only for a custom sound. A successful request returns 204.
  SakuraCord starts local rendering optimistically at click time, in parallel
  with the native request, and suppresses the matching Gateway echo so it does
  not play twice. A rejected native request is still reported without stopping
  local playback that has already begun.
  Playback requires an active voice connection, `SPEAK` (bit 21),
  `USE_SOUNDBOARD` (bit 42), and a voice state that is neither server-muted,
  deafened, nor suppressed. Self-mute does not block a sound and is never
  changed by playback.
- Defaults and same-guild custom sounds use native delivery. Cross-guild custom
  sounds additionally require `USE_EXTERNAL_SOUNDS` (bit 45). Discord's native
  cross-guild route is used for full Nitro (`premium_type == 2`). When that
  entitlement is absent, SakuraCord may instead decode the CDN sound once and
  mix it into the existing outgoing 48 kHz stereo microphone stream. The mixer
  opens no second input or Voice connection: self-muted microphone samples are
  zeroed before mixing, while unmuted samples are layered with the sound.
  Disconnect, engine teardown, or account/session replacement clears every
  queued voice; decode, route, and transport failures send no unrelated audio.
- `VOICE_CHANNEL_EFFECT_SEND` publishes sound effects to connected listeners.
  The observed first-party build also accepted the transitional
  `VOICE_EFFECT_SEND` name, so both names decode to the same bounded domain
  event. SakuraCord locally renders known catalog sounds and resolves an
  uncatalogued valid sound ID through Discord's soundboard CDN. Invalid IDs and
  unavailable media are ignored safely.
- Sound favourites share cloud-backed Frecency settings-proto type 2. Top-level
  field 8 contains ordered, deduplicated packed fixed64 sound IDs in nested
  field 1, capped at 250. An add appends to that stored sequence and a remove
  deletes from it, but the first-party picker does not present storage order:
  available favourites are placed first and each availability group is sorted
  by numeric sound ID. Emoji favourites, by contrast, retain their stored order
  in the picker. One explicit toggle patches the complete updated base64 proto
  and preserves every unrelated or unknown field. A failed favourite mutation
  rolls presentation back to provider-authoritative state.
- Top-level field 11 contains cloud-backed played-sound history. The first-party
  client immediately adds a play trigger to its local pending frecency state,
  ranks up to 32 candidates, and later writes the updated history through the
  settings manager. Its picker removes sounds that are already favourites and
  shows only the first three remaining IDs. The score weights a use from the
  last 3/15/30/45/80 days at 100/70/50/30/10 respectively, with older valid
  samples weighted at 1; total use count scales the sampled-recency score.
- Local and incoming playback share the selected voice output graph and respect
  deafen/output routing. Outgoing mixing is isolated to the microphone encoder,
  permits bounded overlap and repeated triggers, applies a hard sample limiter,
  and keeps the existing RTP timestamp and speaking lifecycle. Device changes
  preserve the session-owned mixer; complete voice teardown clears it.

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
