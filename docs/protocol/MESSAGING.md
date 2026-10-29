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
| Polls and threads | [PollContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/PollContractTests.swift); [ForumProviderContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/ForumProviderContractTests.swift); [ThreadActionContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/ThreadActionContractTests.swift); [ThreadPolicyTests.swift](../../Packages/SakuraCordModels/Tests/SakuraCordModelsTests/ThreadPolicyTests.swift) |
| Uploads | [UploadPrivacyContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/UploadPrivacyContractTests.swift); [UploadCancellationContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/UploadCancellationContractTests.swift); [AttachmentUploadURLValidationTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/AttachmentUploadURLValidationTests.swift); [UploadPrivacyPreparationTests.swift](../../App/Tests/SakuraCordAppTests/UploadPrivacyPreparationTests.swift) |

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

History uses permission-checked channel message reads. Counts and anchors match
the official desktop client (build 650389, captured 27 October 2026) and follow
its viewport formula (module 326337): with `h = max(windowHeight / zoom - 145, 400)`,
`base = max(10, min(30, ceil(1.05 * ceil(h / ((compact ? 65 : 91) * (fontSize / 16))))))`.
A cold newest page, a stale refetch and Jump to Present read `base` messages
(10 in a 794 pt window), the cold page once per channel per uninterrupted Gateway
connection. Scrolling reads `min(30, 2 * base)`: `before={oldest loaded}` upward
and, in a detached window, `after={newest loaded}` downward, one request at a time.
SakuraCord takes the window height from the timeline's hosting window (800 pt before
one reports), divides it by Interface Size as Discord's zoom, and uses the cozy
height and a 16 pt font, having no compact mode and a fixed message text size.
A page is requested once the viewport is within 500 pt of the loaded edge, so a
window shorter than the viewport plus 500 pt keeps loading until it fills. In an
unread conversation the earlier edge waits until the viewport is 18 pt above the
oldest loaded message (the scroller's 16 pt bar buffer plus 2). A jump to
a message not loaded (search, link, reply) is one `around={message}&limit=30` read,
also into a channel with nothing loaded, which reads no newest page first.
Jump to the first unread, when its boundary is not loaded, is one `around` read of 30
centred on the last acknowledged message, never a chain of `before` pages; a
cold open into a long backlog loads only `base` messages and shows the unread bar.
Warm newest-backed pages are session-cached; a Gateway gap invalidates completeness
and refreshes a reopened/selected channel once. Distant navigation replaces the
window with `around` history; older/newer edges paginate independently. It must
not masquerade as a newest-backed cache: leaving a detached window caches it
with its viewport anchor and open later edge, so returning makes no request and
restores the same messages and position. A cached detached window admits no live
message or send, is never acknowledged, and is discarded by a Gateway gap. A
superseded selection may still finish its dispatched read and populate the
account cache without changing selection.
An edge stays open after a full page, counting returned messages that cannot be
decoded. A newest page extends a loaded window only when it reaches messages
known to be gap-free (not ones that arrived live after a Gateway gap);
otherwise it replaces the window rather than joining disjoint blocks.

Threads and forum posts use the same windows, request sizes and 500 pt trigger as
channels. Gateway does not
guarantee a closed thread's messages, so a cached thread reopens at once and
always revalidates its newest page. Until a current read establishes the newest
edge after such a reopen or a Gateway gap, the window counts as detached: sends
load the newest messages first and nothing is acknowledged automatically; a reconnect also revalidates the open
thread and a Guide resource that had reached its newest message. Results for a
closed instance of a side chat, including an earlier one of the same thread,
are discarded, and of competing whole-window reads, sends and returns to the
newest message the latest wins. A read that began before a Gateway gap may
show its messages but cannot mark the window as reaching the newest message
or admit messages past its fetched edge. Earlier and later pages continue from
the window's REST edges, not from the messages it shows, and live messages,
send confirmations and edits never join the window past an edge with more
history beyond it.

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

### AutoMod rejections

An ordinary message POST returning HTTP `400` with Discord code `200000` is a
**definite message rejection**. The provider maps only that status/code pair to
`ChatProviderError.autoModerationBlocked`, retaining the optional response
`message` as plain explanatory text. Other errors, including title-block code
`200001`, retain their existing handling. Do not infer a rule type or a member
timeout from this rejection, stop the account session, or replay it automatically.

The outbox retains the original text, attachments, reply and nonce in the failed
row. The existing red failure tint remains, with the server explanation when
supplied and a short AutoMod fallback otherwise, including accessibility. A
blocked message offers copy and discard, without retry; ordinary failed sends
remain retryable. Authoritative REST/Gateway confirmation replaces the failed row.
A simultaneous [server timeout](GUILDS.md#server-timeouts) independently disables
communication through membership state, including queued delivery and retries.
The block explanation survives timeout expiry; later composer edits are preserved.

Official Fresh host `0.0.411`, web build `641004`
([`web.4d4b2f75fdea5470.js`](https://discord.com/assets/web.4d4b2f75fdea5470.js)),
observed on 18 October 2026, returned one HTTP `400`/`200000` for each controlled
custom-keyword, regex, built-in severe-profanity preset, attachment/reply, and
existing-thread send. Custom rule text arrived in response `message`; the preset
returned a generic server-block explanation. No matching `MESSAGE_CREATE` was
captured. For a custom rule combining block and a 60-second timeout,
`GUILD_MEMBER_UPDATE.communication_disabled_until` preceded the rejected POST
response. The client showed both the private red-tinted blocked row and a disabled
composer/countdown, then restored the composer at expiry. This ordering and the
absence of a matching create are observations, not universal delivery guarantees.
Suspected-spam detection and image safety filters were not triggered by this pass.
A scoped native pass also verified single-attempt rejections for the preset,
attachment/reply and thread cases, retained outbox metadata across navigation,
both composers recovering at timeout expiry, and a successful message in the
same session afterward. Temporary rules and the successful verification message
were removed; a fresh official rules read matched the original configuration.

The same bundle's modules `148494`, `93474`, `232835` and `753738` retain an
AutoMod notice separately from timeout state and display the response explanation;
`779185` retries `429`, not these `400` rejections. The official queue cancels
waiting sends in the same channel after a failure. SakuraCord deliberately keeps
its existing queue policy: later sends recheck eligibility individually and
unrelated conversations remain usable. It also keeps attachments/replies in the
outbox; the observed official attachment rejection
restored text and the attachment to the composer while dropping its reply target.

Discord's [error codes](https://docs.discord.com/developers/topics/opcodes-and-status-codes)
and [Auto Moderation contract](https://docs.discord.com/developers/resources/auto-moderation)
define message blocking, keyword/regex/preset triggers, optional custom block
text and the separate timeout action. Pinned
[Paicord error codes](https://github.com/llsc12/Paicord/blob/5c76f3674e2cace7a6a4369497fcf482f3d9ebe3/PaicordLib/Sources/DiscordModels/Types/Error%20Codes.swift)
corroborate `200000`; its drain retains an unclassified error and paints failed
content red. Pinned
[Swiftcord v1 send handling](https://github.com/SwiftcordApp/Swiftcord/blob/14465d927ebe1ba34b3befa00f9365fad7b56eb9/Swiftcord/Utils/Extensions/MessagesView%2B.swift)
uses a generic send error with explicit retry. Neither establishes a competing
AutoMod-specific presentation contract.

### Embed media

The provider normalizes wire media before presentation: `article` and `image`
embeds promote `thumbnail` into `image`, with an explicit `image` taking
precedence. They do not retain a side thumbnail. Other types, including `link`
and `rich`, preserve the separate image and thumbnail slots. Keep the complete
media metadata and proxy URL during normalization; do not fetch the linked page
to infer its layout. REST history, Gateway updates and forwarded snapshots share
`MessageEmbedDTO` and this rule.

Discord's [embed schema](https://docs.discord.com/developers/resources/message#embed-object)
defines the media slots; its [link-preview guide](https://docs.discord.com/developers/link-previews/overview#preview-layouts)
distinguishes side thumbnails from large images below the text. The first-party
normalization is visible in the [stable web client](https://discord.com/assets/web.c5b338cc7e610833.js)
(`web.c5b338cc7e610833.js`, 16 October 2026):
the article/image cases assign the wire thumbnail to the main image before an
explicit image overrides it. Discord's in-memory message dump therefore differs
from its wire payload. [RichMessageDecodingTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/RichMessageDecodingTests.swift)
protects promotion, explicit-image precedence and link-thumbnail preservation.

## Reactions, pins and forwarding

Reaction intent is serialized per message/emoji with one coalesced follow-up.
If the target is absent from the working set, read `around={message}&limit=1`
before deciding whether PUT/DELETE is needed. Missing/failed reads prevent the
mutation; an already satisfied intent sends nothing.

Reaction changes invalidate the affected emoji's saved previews and pending reads
in both the model and provider, preserving other emojis' loads and previews.
Clearing all reactions invalidates the whole message. A response for an affected
emoji started before a change must not save or apply its
identities, even when removals and additions return the count to its earlier
value. Shared-load waiters recheck the retained reaction before loading again.

View Reactions uses the poll-voter browser's shared people rows and pagination.
Opening or selecting an emoji loads users on demand; scrolling loads subsequent
pages. Each page reads normal (`type=0`) and Super Reactions (`type=1`) with the
same exclusive `after` user ID and `limit=100`, then merges, deduplicates and sorts
the users by ID before taking at most 100. The last returned ID advances both
streams, so a person who used both kinds appears once and neither stream loses
users at a page boundary. Either full response or an unreturned merged suffix
keeps pagination open. These details pages never expand the five-person timeline
preview cache or initiate member/profile lookups. Changes invalidate only the
affected emoji's detail pages, including in-flight results; closing the popover
or changing accounts prevents late publication.

The [documented reaction endpoint](https://docs.discord.com/developers/resources/message#get-reactions)
defines `type`, `after` and limits of 1–100. The official stable client (build
641004, inspected 17 October 2026) shares its `limit/after/type` user loader with
poll voters; reaction responses are raw user arrays, whereas votes use `users`.
[Pinned Paicord](https://github.com/llsc12/Paicord/blob/694761c1938b73bb60bd58942674dfe73aab1135/PaicordLib/Sources/DiscordHTTP/DiscordClient%2BAPIEndpoint.swift)
corroborates that paginated route. Pinned Swiftcord v1 has no equivalent full
reaction-user browser. SakuraCord deliberately combines normal/Super users in
one list rather than presenting separate reaction-kind tabs. Provider contract
tests protect both streams' cursor boundaries and the separate preview budget.

Reaction coalescing reduces requests but does not prevent server rate limits.
A definite reaction `429` records the transport cooldown and returns a typed
rate-limit error to the model. The model retains optimistic state and permits
one retry after that cooldown, using the latest desired state; returning to the
confirmed state cancels the request. Clicks remain interactive throughout the
wait and in-flight retry. A rejected retry or another error rolls back and uses
the existing error presentation. Account teardown or message deletion cancels
pending cooldown work. Each provider invocation still makes only one attempt;
timeouts and ambiguous failures are never replayed automatically.

The [official stable client](https://discord.com/assets/web.4d4b2f75fdea5470.js)
(build 641004, inspected and observed 17 October 2026) likewise keeps its first
rate-limit failure invisible. Its reaction actions retain the optimistic state
on the first `429` and schedule one retry using the
integer `Retry-After` header; rejection of that retry rolls back. Its shared HTTP
helper queues subsequent requests for a rate-limited URL and drains them after
the cooldown with backoff. Rapid same-emoji toggles can still produce overlapping
requests, shared-resource `429`s and delayed queued changes without a rate-limit
dialog. The observed `429`s supplied `Retry-After` and `retry_after` without
bucket/remaining headers; do not infer a fixed reaction quota from successful
requests or treat the debounce interval as a rate-limit budget.

[Pinned Paicord](https://github.com/llsc12/Paicord/blob/694761c1938b73bb60bd58942674dfe73aab1135/PaicordLib/Sources/DiscordHTTP/ClientConfiguration.swift)
corroborates header-driven bounded `429` recovery through its generic HTTP retry
policy. [Pinned Swiftcord v1](https://github.com/SwiftcordApp/Swiftcord/blob/14465d927ebe1ba34b3befa00f9365fad7b56eb9/Swiftcord/Views/Message/MessageRenderViews/MessageView.swift)
has only a stub add-reaction action, with no equivalent retry contract.

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
Poll rejections follow the shared operation-scoped error policy; they do not
stop unrelated REST or Gateway traffic.

## Forums, threads and commands

Forum browsing uses `threads/search` and preview `post-data` batches of at most
ten. Publish the catalogue independently of starter previews. Advance pagination
by raw server records, retain valid siblings and cancel obsolete searches.
Creating a forum post uses one thread mutation after any attachment uploads. Its
nested `message` carries `content` and uploaded `attachments` but no
`sticker_ids` (official build 649389 omits the field).
Composer Create Thread uses one thread POST followed by a message send to the new
thread, with the current public/private-thread permission rules. The request's
`location` is `Plus Button` from the composer and `Thread Browser Toolbar` from
the Threads browser. An unknown
thread link may first require one Get Channel; a known one does not.

Thread lifecycle events advance the parent forum boundary before unread
projection. Metadata, archive, lock, pin and delete are explicit, permission-gated
mutations. Message-created thread cards use cached thread/message data.

### Thread retention

A cached thread leaves the provider only through `THREAD_DELETE`, removal of its
parent channel or guild, or a fresh READY that no longer lists its parent.
Opening a guild channel subscribes it through opcode 37 with `threads: true`.
The resulting `THREAD_LIST_SYNC` carries `threads` and `most_recent_messages`
for every active thread the user can view, joined or not, with no `channel_ids`,
`members` or per-thread `member`. Archived threads are never included. The sync is
add-or-update only, including when `channel_ids` scopes it: absence is not
deletion, archiving or leaving, so archived catalogue pages, linked-thread Get
Channel results and unjoined posts survive it. A `members` entry, when present,
only adds membership. Joined state comes from READY, a `THREAD_CREATE` carrying
`member` (also for a known thread), `THREAD_MEMBER_UPDATE`, and
`THREAD_MEMBERS_UPDATE`, where the current user's ID in `removed_member_ids`
means leaving. Member events apply to any thread known to the post cache or the
joined-thread catalogue. `THREAD_UPDATE` with `archived: true` changes state only.

A fresh READY lists only joined active threads. Public threads learned through
REST survive it while their parent is still listed; their content follows the
parent's permissions, so READY's records restore active membership and the rest
show as unjoined until a member event. Private threads READY does not list are
dropped, because their access follows membership that READY's silence cannot
settle. An open private thread READY does not list is withheld and not presented
for read acknowledgements, with its timeline position reset, while one lookup
resolves it again. Success, or a Gateway record carrying the current user's
member, resolves it in place, keeping its composer work while the recreated
timeline establishes its position; a failure stays unavailable until the user
retries.

A known thread is answered from the provider cache; an unknown one costs one
Get Channel, whose thread `member` states the membership. Thread records and
deletions advance a per-thread record revision, and membership events a
membership revision. A lookup over a cached record applies the response's metadata,
keeping cached previews and owner, unless a record superseded the read; its
`member` applies unless the membership revision moved, because a member-less
record is not evidence of leaving. A lookup whose
record was deleted meanwhile reports the thread as not found; one whose
membership revision moved for an uncached thread asks once more. Resolving an
open private thread's access always performs that Get Channel, even over a
cached record, because a member-less record settles no membership. Opening a
private thread whose record carries no membership, without Manage Threads,
enters that resolution from every entry point; public threads stay cache-first.

The official client instead clears thread channels on `CONNECTION_OPEN` and
refetches the selected thread with Get Channel. Retention keeps an open post and
the loaded catalogue across reconnection; a thread deleted during the disconnect
can stay listed until the account session restarts. RESUMED replays missed events
and resets nothing.

The open thread or forum post closes only on `THREAD_DELETE`, removal of its
parent or guild, or a user action; lost parent access shows it as unavailable.
Leaving it keeps it open. A catalogue page or Gateway list that omits it keeps it
open and listed. Automatic channel reselection happens only when the selected
channel is gone from a loaded channel list of the selected guild or DM scope, or a
guild's channel update or a replacement READY that still lists the guild removes
it, including its last channel. READY offers no cached guild versions, so each
available guild arrives with its complete channel list. An unloaded list or a
guild switch in progress is not removal.

Inbox, pin, search, mention and message-link navigation to a thread no local
projection knows resolves it on demand (cache, else one Get Channel) and reports
failures instead of waiting for background metadata; not-found and forbidden
lookups say that the thread does not exist or is not accessible. Repeating an in-flight
navigation destination, including the requested side-pane or full-width
presentation, does not restart it while nothing else has replaced the side
conversation or guild page since it started; any other destination supersedes it,
as does directly opening another thread or closing the one it is heading to.

Official Fresh host 0.0.411, web build 641004 (`web.4d4b2f75fdea5470.js`),
observed on 19 October 2026 with a moderator and a plain member, confirmed the
opcode-37 sync shape, member-less listing of unjoined threads, join and leave
events, and an open pane surviving a leave. Its ChannelStore, ActiveThreadsStore
and JoinedThreadsStore handlers merge syncs and establish the `CONNECTION_OPEN`
reset and selected-thread refetch; forum-specific branches are source evidence
only, as the test server had no forum.

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
Thread menus resolve [ThreadActionPolicy](../../Packages/SakuraCordModels/Sources/SakuraCordModels/ThreadPolicies.swift)
against their own parent and recheck eligibility when invoking a mutation. Private threads additionally require membership or
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

See [SidebarThreadPresentation.swift](../../App/Sources/SakuraCord/Models/SidebarThreadPresentation.swift).
Observed in official web build `b70721f9bc10ca0b` (desktop host 0.0.411) on
2026-10-06, where it matched 5 of 51 joined forum posts exactly.

### Thread actions and browser

[ThreadPolicies.swift](../../Packages/SakuraCordModels/Sources/SakuraCordModels/ThreadPolicies.swift)
owns the action, creation and naming rules;
[DiscordRESTThreadActions.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordRESTThreadActions.swift)
and [DiscordRESTForumAndMessaging.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordRESTForumAndMessaging.swift)
own the requests. Each mutation is attempted once. These contracts follow
official web build 641004 (desktop host 0.0.411), observed on 2026-10-19.

Every REST result follows one rule, extending the [retention](#thread-retention)
revisions. A response is reconciled against the revisions captured when its
request started, never applied as if it were a Gateway event: a deletion
meanwhile fails a mutation or drops a read's record, and newer cached records
and membership are kept. Every accepted REST change, including each PATCH step,
a created thread and a join or leave confirmation, advances the matching revision
before it is published, so an older read still in flight cannot undo it. Gateway
events and local mutations also advance a separate epoch per thread; only that
epoch supersedes a pending mutation's result, so an overlapping read never
cancels a PATCH, create or join/leave confirmation.

Rename sends `PATCH /channels/{thread}` with only `name`, trimmed to 1–100
characters. The first-party settings page saves its whole form; the minimal body
cannot overwrite other settings with stale values. An archived thread is first
unarchived with `{"archived":false}` and stays open, as before tag, lock and pin
changes. The sequence is one provider operation that is never replayed; each
completed step is committed as it returns, so a failed rename leaves the thread
open. Edits to one thread run one at a time, each starting from the record the
previous one committed. A PATCH result is ignored when a Gateway record or another mutation
superseded it, and reports not found when the thread was deleted meanwhile. Any
membership change meanwhile keeps the provider's membership even when the
response carries `member`, and a response without `member` never changes it.
Discord then sends
`THREAD_UPDATE`, `THREAD_MEMBER_UPDATE` and a type-4 name-change message in the
thread; the republished catalogue renames sidebar rows, the open thread and
starter cards. Renaming requires Manage Threads or ownership of an unlocked
thread; an archived thread also requires the send rights that would reopen it.

Join (Follow) and leave (Unfollow) are `POST` and `DELETE`
`/channels/{thread}/thread-members/@me?location=…` without a body; joining is
not `PUT`. A full thread answers with code `30033`, shown in the application
alert as "Cannot join thread" ("Cannot join post" for forum posts) and a
member-limit explanation. `location` names the surface: `Context Menu` for channel-list and
forum-card menus, `Sidebar Overflow` for the side-pane menu, `Toolbar Overflow`
for the full-view menu and `Forum Toolbar` for the post header. A 204 updates
known threads immediately unless a Gateway membership event or a newer join or
leave arrived while it was pending. The Gateway member events listed
under [retention](#thread-retention) remain authoritative; a confirmation never
replaces a member they already delivered. Notification responses also publish
the joined-thread catalogue.

Starting a thread from a message posts
`POST /channels/{parent}/messages/{message}/threads` with `name`, `type` (`10`
under an announcement parent, otherwise `11`), `auto_archive_duration` (the
parent's `default_auto_archive_duration`, else 4320) and `location: "Message"`.
The 201 thread has the message's ID and the creator's `member`; its first message
is an ordinary send. Discord usually delivers, before that response, a starter
`MESSAGE_UPDATE` carrying only `flags: 32`, a member-less `THREAD_CREATE`
(`newly_created`), `THREAD_MEMBER_UPDATE`, and a type-21 starter reference in the
thread. The parent can also receive a type-18 "started a thread" message; it was
observed for an older starter but not for the channel's newest message. The
type-21 reference quotes the starter only through `message_reference`, so the
quote comes from the cached parent message, and it is not counted as a reply. Whichever arrives first, the
provider attaches the known thread to the starter so its card appears without a
history reload. A confirmed message of type 0, 19, 20, 23, 26, 41, 45, 47 or 68
posted directly in a text, announcement or forum parent qualifies when it lacks
flag 32 and the user has Create Public Threads and Read Message History (forum
parents: Send Messages). Message threads are public; messages inside threads and
voice-channel chats never qualify. The default name is the first embed title
(40 UTF-16 units plus `...`), else the poll question (80), else the first
readable line without leading `#`, `-` or spaces, cut at a word boundary within 40;
spoilers read as `<spoiler>`.

The thread browser pages archived threads with
`GET /channels/{parent}/threads/search?archived=true&sort_by=last_message_time&sort_order=desc&limit=25&tag_setting=match_some&offset=N`,
advancing by raw records while `has_more`; a thread deleted meanwhile is omitted
from both the page and the cache, which also guards the forum catalogue. Search
runs on submit with
`?name=<query>&tag_setting=match_some` and returns active and archived matches as
one page. Responses carry `threads`, the current user's `members`, `has_more` and
`total_results`; text channels omit message previews. Discord did not return an
archived private thread to a non-member without Manage Threads. Joined and other
active threads come from the retained local thread state without a request. Browsing requires View Channel and Read Message History on a
text or announcement parent.

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

Message `interaction_metadata` names the command and its user, never its option
values. Opening the command indicator above a reply reads them with GET
`/channels/{channel}/messages/{message}/interaction-data` (official web build
653945, 2026-10-29). The response repeats the invocation's `name` and executed
`options`, including subcommand wrappers, ID-string entity values and registered
choice values, plus the full `application_command` definition whose
`name_localized` and choices supply display labels. The official client skips
the read for invocations still in its local interaction store, shows a spinner
until the response arrives, and leaves the spinner when the read fails.

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

## Embedded video playback

Video previews use the thumbnail as their large poster rather than a second
side image. Image/video/GIFV cards omit descriptions, and provider metadata
precedes the author and title, matching the first-party renderer. YouTube player
URLs are web content, not AVFoundation media: an explicit preview activation
opens the existing media viewer with a nonpersistent `WKWebView`. Only validated
YouTube embed destinations enter that path; direct media retains native playback.
The player sends the installed bundle identifier as its Referer, as required by
[YouTube's WebView integration contract](https://developers.google.com/youtube/terms/required-minimum-functionality#referer-format).
The [IFrame Player API](https://developers.google.com/youtube/iframe_api_reference)
reports progress to an in-memory, video-keyed session store. Closing the viewer
unloads the player; reopening resumes its position while SakuraCord remains open.
Finished videos clear their resume point, and restarting the app clears all
positions. No playback history is persisted. Hosted videos expose watch links rather
than file downloads; scrolling only loads the supplied poster through the media
cache and never instantiates a player.

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

A message's files share one reservation, then every storage PUT starts at once.
The official client (web build 653945, observed 29 October 2026) also PUTs in
parallel, but reserves each file separately and starts as soon as it is attached;
SakuraCord starts after Send. Each file reports its own progress and can be
stopped alone: its PUT is cancelled and the message is posted without it.
Stopping every file posts nothing. A failed upload leaves the message failed for
explicit Retry, which reserves and uploads again. The official client instead
resumes a failed PUT by itself every few seconds; SakuraCord does not replay
storage PUTs.

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

## Voice messages

Discord's desktop client has no recorder. The send contract was observed on
9 October 2026 (web build `web.ae482d0492df0fb9.js`) through Equicord's
VoiceMessages plugin, which reuses Discord's uploader, and cross-checked against
[Discord's message documentation](https://docs.discord.com/developers/resources/message#voice-messages).

- **Recording.** Mono 48 kHz Ogg Opus. Apple frameworks encode Opus but write it
  only into CAF, so [MediaPipeline](../../Packages/MediaPipeline/Sources/MediaPipeline/OggOpusWriter.swift)
  muxes the packets itself: 312-sample pre-skip, with the final granule trimming
  encoder padding. Never upload CAF renamed to `.ogg`. Recordings stop at
  Discord's 20-minute limit. Capture applies no gain, so the recording is
  levelled once it stops: gated speech to −16 dBFS RMS, at most +18 dB, with a
  soft limiter. The waveform is measured after levelling.
- **Waveform.** 32–256 bins, ten per second of audio: RMS scaled to 0–255, then
  the plugin's eased peak normalization, base64-encoded as raw bytes. Follow
  upstream Vencord's contiguous windows; the installed Equicord copy contains an
  indexing bug.
- **Upload.** The reservation names `voice-message.ogg` and adds
  `original_content_type: "audio/ogg; codecs=opus"`. Storage receives the raw
  bytes as `application/octet-stream`. The message POST sets `flags: 8192` and
  empty `content`, plus one attachment with `filename`, `uploaded_filename`,
  `duration_secs` and `waveform`. The attachment's `content_type` is omitted.
- **Rules.** Guild channels require Send Voice Messages (`1 << 46`). A voice
  message carries no text, stickers or poll, and Discord does not allow it to be
  edited.
- **Delivery.** Unlike the plugin's direct POST, SakuraCord sends through the
  ordinary [outbox](#sends-and-history). It keeps the nonce, idempotency field,
  send budget and reply reference.
- **Receipt.** `MESSAGE_CREATE` and history carry `flags: 8192`, plus an
  attachment with `content_type: audio/ogg`, `duration_secs` and `waveform`.
  Preserve the returned metadata; Discord may adjust the duration (8 → 8.02
  observed).
- **Playback.** Audio is fetched from the attachment `url` through the shared
  media cache, re-signing expiring links first. One message plays at a time. The
  speed cycle is 1×, 1.5×, 2×, 0.75×, kept device-local. Up to 25 resume
  positions between 0.5 s and 95% are kept in memory. Listening is not reported
  to Discord.

See [VoiceMessageSendContractTests](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/VoiceMessageSendContractTests.swift)
and [VoiceMessageEncodingTests](../../Packages/MediaPipeline/Tests/MediaPipelineTests/VoiceMessageEncodingTests.swift).

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
