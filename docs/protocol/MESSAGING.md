# Messages and uploads

[Protocol index](../PROTOCOL_BASELINE.md)

## Owners and checks

[DiscordRESTProvider](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordRESTProvider.swift)
and its neighbouring feature files own network requests. App's
[composer state](../../App/Sources/SakuraCord/Models/MessageComposerState.swift) owns drafts
and the outbox; MediaPipeline owns local media transformations.

| Contract | Representative checks |
| --- | --- |
| DM/history/send budgets | [DirectMessageProviderContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/DirectMessageProviderContractTests.swift); [ProviderRequestContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/ProviderRequestContractTests.swift); [MessageSendRateLimitContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/MessageSendRateLimitContractTests.swift) |
| Search, forwarding and pins | [MessageSearchContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/MessageSearchContractTests.swift); [MessageForwardingContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/MessageForwardingContractTests.swift); [PinnedMessagesContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/PinnedMessagesContractTests.swift) |
| Polls and threads | [PollContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/PollContractTests.swift); [ForumProviderContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/ForumProviderContractTests.swift) |
| Uploads | [UploadPrivacyContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/UploadPrivacyContractTests.swift); [AttachmentUploadURLValidationTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/AttachmentUploadURLValidationTests.swift); [UploadPrivacyPreparationTests.swift](../../App/Tests/SakuraCordAppTests/UploadPrivacyPreparationTests.swift) |

## Sends and history

Opening/selecting a conversation, fetching history and sending are distinct
operations. An ordinary message POST carries content, nonce, TTS/flags and
`mobile_network_type`, with attachments/reply reference when present and
`chat_input` context. SakuraCord adds `enforce_nonce:true` for ordinary messages
as a deliberate idempotency safeguard. Concurrent same-channel/same-nonce sends
share one mutation. Preserve that nonce for explicit retries; an ambiguous result
must not cause automatic resend. [Poll creation](#polls) has a distinct body.

Like the first-party `MessageQueue` (stable web build `web.ae482d0492df0fb9.js`,
observed 9 October 2026), the account's outbox delivers one send at a time in
submission order. The composer clears as soon as a message is admitted, so later
messages can be written and queued while earlier ones are in flight. Unconfirmed
sends, including failed ones awaiting retry or discard, stay below settled messages
in submission order, so each confirmation settles in place instead of moving by
its server timestamp. While five
sends wait behind the one in flight, a new submission is refused before it
consumes the draft and the "Way too spicy" alert is shown. A non-slowmode `429`
on the message POST is a definite rejection: the transport waits for the server
cooldown and replays the same body and nonce within the
[message creation budget](../PROTOCOL_BASELINE.md#attempt-budgets), without
re-uploading attachments. The first-party queue replays without a bound;
SakuraCord stops after the budget and leaves the message failed for explicit retry.
Forwarding and the `/msg` and `/thread` built-ins post to another conversation
outside this queue; forwarding keeps the single-attempt mutation budget.

A reply includes reference type 0, message ID and channel ID. To disable the reply
ping, include `allowed_mentions` with normal users/roles/everyone parsing and
`replied_user:false`; do not suppress unrelated content mentions accidentally.
Current permissions, membership gates and slowmode are checked before consuming
a draft or dispatching any send entry point. REST/Gateway confirmations reconcile
the same optimistic message rather than creating duplicates.

History uses permission-checked channel message reads. A cold newest page loads
10 messages once per channel per uninterrupted Gateway connection. Warm
newest-backed pages are session-cached; a Gateway gap invalidates completeness
and refreshes a reopened/selected channel once. Distant navigation replaces the
window with `around` history; older/newer edges paginate independently. It must
not masquerade as a newest-backed cache. A superseded selection may still finish
its dispatched read and populate the account cache without changing selection.

Search uses guild search or read-only DM search. Pagination and indexing follow
server cursors and the [shared budgets](../PROTOCOL_BASELINE.md#attempt-budgets).
Rendering a result, reply, embed or thread card does not trigger detail fetching.
Sparse edits, deletions and author updates must reach retained presentation even
when the provider's bounded working set has evicted the underlying message.

Webhook authors retain their message-scoped identity (`webhook_id`, name and
avatar), including reply previews. They must not enter the ordinary user index
or inherit a cached member's nickname, avatar, roles or presence. The profile
popover renders that identity locally without a `/users/{id}/profile` request;
real bot users responding through interactions still use normal profiles.
Live `/sayas` verification on 2026-10-05 observed a newly supplied avatar arrive
as `null` in `MESSAGE_CREATE`, followed by a complete webhook `author` in
`MESSAGE_UPDATE` once Discord had processed it. Apply that author only to the
target message, including retained projections and its open profile popover;
preserve other personas and reply snapshots sharing the same webhook ID.
Discord's 2026-10-04 client identifies non-user bots by discriminator `0000`
and uses the first default avatar when their avatar is absent. This agrees with
the [message author contract](https://docs.discord.com/developers/resources/message#message-object)
and Swiftcord's webhook profile-fetch exclusion; pinned Paicord retains the
raw author fields but has no equivalent dedicated profile path.

## Reactions, pins and forwarding

Reaction intent is serialized per message/emoji with one coalesced follow-up.
If the target is absent from the working set, read `around={message}&limit=1`
before deciding whether PUT/DELETE is needed. Missing/failed reads prevent the
mutation; an already satisfied intent sends nothing.

Pin/unpin uses the dedicated `PIN_MESSAGES` permission and the message-pins
route. One mutation per message runs at a time. Definite rejection rolls back;
ambiguous failure is reconciled without automatic replay. Pin pages and Gateway
pin/message updates share the same authoritative state.

Forwarding sends one explicit message per selected destination with a type-1
reference, first-party forwarding context and permission checks. Destinations
are independent outcomes; a partial failure must not replay successful sends.
Forwarded snapshots render locally and do not authorize reads of the source.

## Polls

Creation is an ordinary message POST with `poll_creation` context, empty content,
nonce and poll data, but **without `enforce_nonce`**. Question/answer limits and
duration choices live with the validation model and contract tests. Answers use
`poll_media`; Discord assigns answer IDs. Guild creation requires `SEND_POLLS`.

Vote PUT replaces the entire selection using **string** `answer_ids`, including
an empty array to remove votes. Voter GETs use `limit=100&type=2` and an exclusive
`after` cursor; known zero counts need no request. Only the author explicitly
ends an active poll, through an empty-body expire POST. Poll messages are not
editable through ordinary message editing.

Vote events patch retained projections in order. Missing historical results are
unknown, not zero. Final counts cannot be replaced by stale REST results or
omitted fields; non-personalized final `me_voted:false` values must not erase a
known personal selection. Natural expiry and rendering send no expiry request.
An explicit results read can repeat once if overlapping votes make its unversioned
tally ambiguous; a second overlap reports failure rather than starting polling.
Expected route-scoped poll errors stay local, while account restrictions retain
the shared safety circuit.

## Forums, threads and commands

Forum browsing uses `threads/search` and preview `post-data` batches of at most
ten. Publish the catalogue independently of starter previews. Advance pagination
by raw server records, retain valid siblings and cancel obsolete searches.
Creating a forum post uses one thread mutation after any attachment uploads.
Composer Create Thread uses one thread POST followed by a message send to the new
thread, with the current public/private-thread permission rules. An unknown
thread link may first require one Get Channel; a known one does not.

Thread lifecycle events advance the parent forum boundary before unread
projection. Metadata, archive, lock, pin and delete are explicit, permission-gated
mutations. Message-created thread cards use cached thread/message data.

### Sidebar threads

The channel list needs no request. READY and `GUILD_CREATE` `threads` contain only
active threads the account has joined, each with an embedded `member` whose
`join_timestamp` orders the rows. A created thread arrives as a member-less
`THREAD_CREATE` followed by `THREAD_MEMBER_UPDATE`; joining yields
`THREAD_MEMBERS_UPDATE` `added_members` plus a `THREAD_CREATE` with `member`;
leaving yields `removed_member_ids`; closing yields an archived `THREAD_UPDATE`.

Discord lists a joined thread under its text, announcement or forum parent only
while it is relevant: its auto-archive window has not elapsed since the latest of
its last message (or creation), `last_non_message_activity_timestamp`, and
`archive_timestamp`, it is pinned, it is unread
and not muted, or it has mentions. A collapsed category or muted parent keeps
only unread-and-unmuted or mentioned threads unless the parent or one of its
threads is open. Rows sort by newest join; a selected full-channel thread absent from that set is
inserted first. A thread open only in the side pane does not receive that exception.
`hide_muted_channels` removes muted, unmentioned threads unless their parent or
one of its threads is selected. Relevance and timed mute expiry re-evaluate the rows.
Sidebar selection and channel keyboard traversal open the existing thread timeline
as the main conversation; the hidden parent is not eligible for read acknowledgements.
Thread menus resolve permissions against their own parent and recheck eligibility
when invoking a mutation. Private threads additionally require membership or
Manage Threads to expose content or actions after leaving. Close requires Manage Threads or the unlocked thread's
creator; reopening an unlocked thread uses the first-party send permissions,
while reopening a locked thread requires Manage Threads. Lock/unlock and pin/unpin
require Manage Threads; pinning is forum-only. Ordinary thread creators cannot
delete a thread without Manage Threads. Forum authors may delete an empty post;
deleting only a starter message after replies exist is a separate action, not
permission to delete the whole thread. Notification controls require membership;
unjoined threads must not implicitly join through a sidebar notification change.
These gates follow first-party modules 406704, 307623, 57907, and 375500 in the
2026-10-06 official client. Sidebar action failures use a visible application alert,
including when the forum browser is not presented.

Follow/leave uses
`POST`/`DELETE /channels/{id}/thread-members/@me?location=Context%20Menu` and
reconciles membership through Gateway; notification responses also publish the
joined-thread catalogue immediately.
See [SidebarThreadPresentation.swift](../../App/Sources/SakuraCord/Models/SidebarThreadPresentation.swift).
Observed in official web build `b70721f9bc10ca0b` (desktop host 0.0.411) on
2026-10-06, where it matched 5 of 51 joined forum posts exactly.

Text-channel and voice-channel chats, existing threads, and existing forum posts
support the same slash-command composer. The main conversation and supplementary
thread pane own separate command drafts, autocomplete work and member results,
while sharing account-scoped command usage. Thread availability uses the parent
channel; execution, autocomplete, attachments and responses use the thread ID.
Closing or replacing a pane invalidates its pending editor work. Thread and forum
creation drafts do not execute commands before Discord has created a destination.

The active conversation preloads the user command index plus a context index
only for a guild or a one-to-one DM whose recipient is a bot. Human and group
DMs use `/users/@me/application-command-index`; bot DMs additionally use
`/channels/{id}/application-command-index`, including a valid empty catalog.
An unavailable channel index fails locally without stopping the session or
discarding user-installed commands. These targets were verified in official
web build `1c978ae014dc4bbaddcb5a9a5140ffd05d004bad` on 2026-10-05.
Preserve an application's `bot_id` even when its expanded `bot` is absent;
it identifies the recipient for Discord's [bot-DM interaction context](https://docs.discord.com/developers/interactions/application-commands#interaction-contexts).
Explicit command contexts take precedence, including an empty list. Legacy
definitions without `contexts` allow guilds and the application's bot DM unless
`dm_permission` is false, in which case only guilds are allowed; they do not
implicitly allow human or group DMs. This follows the same observed web build.
Requests are coalesced and cached per target. A picker opened before preload finishes
shows its loading state. Channel changes reapply availability and can reuse the
prepared search index only when the full filtered catalog and locale match.
The index decoder retains unknown root fields while decoding typed commands;
malformed entries and unrepresentable integer choices do not discard the usable
catalog. Search, option editing and cached entity resolution are local.
Autocomplete sends type 4 with the desktop client's 500 ms leading/trailing
debounce: the first distinct query starts immediately, and a typing burst sends
its latest query after a quiet interval. Cached choices need no request, and
obsolete queued work is cancelled before dispatch. Execution sends type 2,
with attachment uploads completed first. Pending nonce state reconciles through
Gateway events. Invocation `guild_id` and command-registration `data.guild_id`
have different meanings; the latter appears only for guild-scoped commands.

The picker reproduces the official client's ordering (desktop build of
2026-10-04): application sections by bot name with the collator Discord uses,
Discord's client-side built-ins last, Frequently Used as the five
highest-scoring browse commands among the 100 most frecent, and typed search
ranked by Discord's match tiers, then frecency score, then name, at most 20.
[ApplicationCommandPickerEngine.swift](../../App/Sources/SakuraCord/Models/ApplicationCommandPickerEngine.swift)
and [DiscordFrecencyStore.swift](../../App/Sources/SakuraCord/Models/DiscordFrecencyStore.swift)
own those rules; [ApplicationCommandFrecencyTests.swift](../../App/Tests/SakuraCordAppTests/ApplicationCommandFrecencyTests.swift)
pins them. The command list uses the emoji picker's bounded native viewport and shared
section rail. Section headings scroll in the list, pin at the top, and are pushed
out by the next section; command rows are clipped below the pinned heading.
Command help sits above the
composer so activation preserves the input bar geometry. Search retains only
the best 20 candidates; keyboard rows are prepared once per result set.

The active editor permits navigation into the command name; editing that name
returns to ordinary text while preserving argument names and values. Tab and
Shift-Tab select existing argument values. Accepting a suggestion advances to
the following gap without submitting; an unselected option list takes one Tab
to select and another to accept. Empty required chips can be removed, but
submission restores the missing field instead of sending. Shift-Return retains
newlines in string values. Refocusing a resolved remote choice requests its
displayed text while preserving the selected wire value until edited. These
keyboard and autocomplete rules were checked with official web build
`1c978ae014dc4bbaddcb5a9a5140ffd05d004bad` on 2026-10-05.

SakuraCord's own commands form an extra section that never enters
synced usage.

The message Apps menu uses the same command matching and synced frecency as
the composer. Its frequent section contains up to five available commands
from the synced top-100 history, without filling unused slots from global
popularity. Menu search treats its input literally and retains all matches;
composer option-boundary parsing and its 20-result limit do not apply.

Command usage syncs through Frecency type 2 field 7 (see
[Settings](SETTINGS.md#emoji-gifs-stickers-and-sounds)). Keys are the command
ID with subcommand names joined by NUL, suffixed `:guildID` for guild-registered
commands, and negative IDs for built-ins. Uses stay pending, survive relaunch
and replay over newer synced history. Saves are serialized per account and
acknowledge only their captured usage prefix; uses recorded during a save stay
pending. Gateway echoes wait until the save settles to avoid replaying an
already accepted prefix. They are saved as one field-7 PATCH
10 ms plus up to ten seconds after the Gateway becomes ready, every two hours
plus up to ten minutes, and when the connection closes. Desktop focus loss and
minimization do not flush usage: the official client's `APP_STATE_UPDATE`
background trigger is distinct from window focus. A received type-2 Gateway
settings update refreshes the live picker without reloading the receiving app.
These timing and two-session rules were checked in Discord Official Fresh
0.0.411, web build `01ad17390800dffe4fbc9791dab1081e4b5290fd`, on 2026-10-05.
Built-ins run locally: text
built-ins send an ordinary message (`/tts` sets `tts:true`), `/msg` and
`/thread` use the ordinary DM and thread routes, and `/gif` and `/sticker` open
the native pickers. `/nick` makes one PATCH to
`/guilds/{guild_id}/members/%40me/nick` with `{"nick":"value"}`; submitting
without a value sends `{"nick":""}` and resets the server-specific nickname.
The HTTP 200 member response returns `nick:null` for a reset, and
`GUILD_MEMBER_UPDATE` synchronizes other sessions, potentially before HTTP
completion. Confirmations stay local. The profile-save guard serializes this
mutation with profile editing; it is never automatically replayed. Recognized
nickname-field validation errors remain local, and an intervening Gateway
profile update takes precedence over the REST snapshot. The official user
client still uses this nickname-specific route despite the public API's
recommendation to use Modify Current Member; other members' and friend
nicknames are described under [nicknames](SETTINGS.md#nicknames). Moderation, group-leave and
schedule built-ins show a local notice. Built-in notices use Discord's local
Clyde identity (user `1`, discriminator `0000`), never a remote user-profile
request. Official Fresh 0.0.411 on 2026-10-05 showed a compact Clyde card with
its bundled avatar, `#5C64F3` banner, verified APP badge, and Copy User ID only.
Discord requested `/users/1/profile` and received 404 before displaying its
local card; SakuraCord directly presents that card without the failing fetch.
SakuraCord deliberately omits the local identity’s profile action menu.

Official Fresh 0.0.411, web build `1c978ae014dc4bbaddcb5a9a5140ffd05d004bad`,
was checked on 2026-10-05 in SakuraCord Testing Server. Typing into an active
command's empty gap implicitly enters its option only when it has exactly one
declared option, that option is optional and not an attachment, and no chip is
present. A single remaining option of a multi-option command does not qualify;
neither does a removed required option. Whitespace and a literal `name:` enter
the value too. Pasted gap text is flattened to one line; option values retain
pasted line breaks and Shift-Return editing.

### Interaction envelopes and lifecycle

The following user-client contracts were observed in the official desktop web
build 627798 on 2026-10-03. They describe the wire boundary, not enabled native
capabilities; the [capability gates](../PROTOCOL_BASELINE.md#capability-gates)
still apply. Public [command](https://docs.discord.com/developers/interactions/application-commands),
[callback](https://docs.discord.com/developers/interactions/receiving-and-responding)
and [component](https://docs.discord.com/developers/components/reference)
documentation describes the application-facing boundary, which normalizes some
fields differently from the user-client request.

POST `/interactions` uses separate namespaces: interaction type 2 executes a
command, while `data.type` identifies chat input (1), user context (2) or message
context (3). Context commands carry `data.target_id`. Chat-input options retain
subcommand/group wrappers, typed numbers and booleans, ID-string entity values,
and registered choice values rather than display labels. Execution includes the
selected full command definition and `data.attachments`, empty when unused.
The embedded definition is the index entry plus two client additions:
`name_localized` and non-empty `description_localized` repeat the displayed text
on the command, options and choices when the index omits them, and context
commands gain `description:""` and `options:[]`. Unknown index fields pass through.
Autocomplete type 4 retains selected siblings and the focused option's value
and `focused:true`, including an empty string; it omits execution attachments
and analytics fields. Correlate choices by nonce and draft generation. Success
can precede choices; obsolete results must not replace the current draft.
Autocomplete suggestions do not restrict execution to listed values.

Component type 3 carries the source `message_id` and `message_flags`. Button data
contains `component_type:2` and `custom_id`, without a `type` or `values` field.
Observed selects include both `component_type` and `type` (3, 5, 6, 7 or 8), plus
`custom_id` and selected `values`. Preserve selection order. Edited message
selects can commit when the dropdown closes, including with Escape; closing an
unchanged selection sends nothing. This differs from modal cancellation.
Nested V2 controls retain their source application and message identity.
Delivered V2 media uploaded with the message keeps a CDN `url` and adds
`attachment_id`, while `attachments` can be empty; render from the URL.
Ordinary bot-authored messages can omit the application and interaction
metadata. SakuraCord resolves their application from the bot author, excluding
incoming webhook identities; scoped fixture execution verifies this path.

HTTP 204 acknowledges transport, not completed output. Reconcile
`INTERACTION_CREATE`, `INTERACTION_SUCCESS`, `INTERACTION_FAILURE`, modal events
and message events independently; Gateway events can precede the HTTP response.
Failure `reason_code:2` was observed for missing application acknowledgement.
A bot-authored permission error can instead be a successful interaction result.
A returned modal or correlated message settles its opener even if a separate
success event is absent. Local acknowledgement deadlines begin after transport
acceptance, excluding attachment preparation and upload. A later transport
failure must not overwrite a Gateway-confirmed result. Failed submission input
is restored only if its original conversation still has an empty composer;
SakuraCord never automatically repeats the interaction.
Deferred acknowledgement can clear pending state before the eventual edit.
Loading messages transition flags 128 to 0 publicly or 192 to 64 privately,
retaining their message ID. The client renders flag 128 as its three-dot
loading indicator with "{app} is thinking…" instead of the body; its local
"Sending command…" row before acceptance is not private. An activated button
shows the same dots in place of its label. Followups can omit the original nonce. Ephemeral
updates can omit `guild_id`; retain originating channel/guild context. Local
ephemeral dismissal sends no DELETE, unlike authoritative `MESSAGE_DELETE`.
Ephemeral rows expose dismissal and their own component controls, but no message
hover capsule, context menu or accessibility message actions.

### Returned modals and files

`INTERACTION_MODAL_CREATE` supplies nested `application.id`, opening interaction
`id`, `nonce`, `channel_id`, title, custom ID and components; observed events omit
top-level `application_id` and `guild_id`. Retain original invocation context.
Opening success must not dismiss the modal. Submit interaction type 5 with a
**fresh nonce** and `data.id` equal to the opening interaction ID, including when
a message component opened it. No source `message_id` is added to the observed
modal submission. Cancel/Close/Escape are local and send no cancellation request.
A definite form rejection retains values for an explicit corrected submission;
that submission keeps the opener ID and receives another fresh nonce.

Preserve legacy action-row wrappers (`type:1`, `components`) and modern labels
(`type:18`, singular `component`). Incoming numeric component IDs are omitted in
observed submissions. Explanatory text-display nodes remain as `{type:10}` without
display content. Controls retain defaults, required/count/length constraints,
entity channel filters and file-type metadata independently of presentation.

Text/radio use scalar `value`, checkbox uses boolean `value`, and selects,
checkbox groups and uploads use `values`. Untouched optional text/radio can send
null; untouched optional lists can send null. Explicitly cleared text sends an
empty string; cleared optional message selects send an empty array. Defaults
are submitted without editing, and false remains an explicit checkbox value.
Do not copy bot-normalized empty strings/lists into the client builder. Observed
text minimum validation uses Unicode scalars on the server, while the official
browser's local check uses UTF-16 code units; Swift grapheme count matches neither.
The non-ASCII maximum truncation boundary has not been verified.

On 2026-10-04 SakuraCord's native implementation was compared field-for-field
against the official client in a test server: chat-input options of every type,
autocomplete (initial empty and typed queries), buttons including deferred,
private and missing-acknowledgement responses, string and entity selects
(including clearing a default), text/optional/defaults/choices modals opened by
commands and components, and message and user context commands. Request bodies
matched apart from snowflakes and key order. Modal file uploads were not
compared live.

Interaction uploads use channel attachment reservation and storage PUT before
submission. Preserve the existing [privacy and storage boundaries](#attachments).
Final `data.attachments` is an array of descriptors with string `id`, filename,
uploaded filename and original content type. A command attachment option's
`value` is a numeric index; modal upload controls use arrays of numeric indices
into one attachment table spanning all controls. These are distinct from
reservation slot IDs and final attachment snowflakes. Discord later transforms
them into bot-facing snowflake references and `resolved.attachments`; the client
does not submit that resolved map. Removing a prepared file changes the local
draft; no remote deletion was observed. Re-adding reserves a new upload.

## Attachments

Privacy preparation precedes reservation and external multipart construction.
Use the prepared byte count for caps and reservations. Enabled-by-default metadata
removal makes local copies of supported images/videos, preserving orientation and
colour profiles. It does not modify the original. Documents, archives and
standalone audio are outside this policy. Unsupported/corrupt media require
explicit approval to upload unchanged; approval covers exact bytes and is
invalidated by file changes or account reset. Upload from a stable private copy.

Compaction is separate and attempted only for oversized media according to its
policy. A prepared or compacted file fitting the account cap is accepted,
including equality at the boundary. The provider repeats the cap check before
reservation. Discord-issued upload URLs are validated and receive only the
headers needed for storage, not account credentials.

Compression and external-host preferences live in **Settings → Features**;
unavailable dependent controls remain visible but disabled. Both policies default
to Ask. A named host selection or saved Automatically policy authorizes external
upload. Never skips that path. The uploader receives no Discord token, cookie,
client metadata or message body. It accepts only the configured host's validated
HTTPS result and inserts the URL into the originating draft; it never sends the
message. Account limits and host caps are maintained by their implementation,
not a second documentation constant table.

See [external-host checks](../../App/Tests/SakuraCordAppTests/ExternalAttachmentUploaderTests.swift)
and [metadata fixtures](../../Packages/MediaPipeline/Tests/MediaPipelineTests/UploadMetadataTests.swift)
for failure/privacy boundaries. Detailed container algorithms belong beside that
code, not in the transport-wide baseline.

## Attachment links

Attachment URLs retain their ordinary full-URL presentation. An explicit
activation refreshes an unsigned or nearly expired HTTPS attachment URL only
when its complete URL matches the first-party attachment-link rule: `cdn`,
`media`, or `images` Discord CDN hosts (including subdomains and hyphen-suffixed
variants), an `/attachments/` or `/ephemeral-attachments/` path, numeric IDs,
and the rule's filename/query character set. Nonmatching URLs remain ordinary
links; no URL prefix is substituted for the original destination.

SakuraCord deliberately applies refresh to any activated link whose complete
URL matches that rule, including masked links. The first-party client refreshes
attachment-link clicks and its "Copy link" item; SakuraCord has no message link
context menu. The refreshed destination still goes through external-link safety
assessment with the original displayed label. This activation path does not
refresh image embeds, attachments, or the media viewer. The first-party client
separately detects expired attachment and embed URLs when loading a channel and
refetches message history.

| Route | Contract | Evidence |
| --- | --- | --- |
| `POST /attachments/refresh-urls` | One explicit activation of a Discord attachment link whose URL is unsigned or whose hexadecimal `ex` expires within one hour; `attachment_urls` contains exactly the original URL. `refreshed_urls[0].refreshed` is opened; a null or absent value opens the original URL. No retry, context header, or cache. | Stable web build `622805` (`web.d4c7976eccf337f1.js`, SHA-256 `7341aa3d5a2208664901f65bf776a48fb5cafe21a1a9e6ce504db79a4a636f7d`), 28 September 2026. Public docs define `ex`/`is`/`hm` but not this route; pinned Paicord and Swiftcord v1 have no equivalent contract. |
