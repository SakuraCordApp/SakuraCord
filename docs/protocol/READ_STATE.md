# Read state and Inbox

[Protocol index](../PROTOCOL_BASELINE.md)

## Owners and checks

[AccountReadStateModel](../../App/Sources/SakuraCord/Models/AccountReadStateModel.swift)
owns acknowledgement state; [InboxState](../../App/Sources/SakuraCord/Models/InboxState.swift)
owns Inbox presentation. Network operations live in
[DiscordRESTInbox.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordRESTInbox.swift) and
[DiscordRESTInboxEvents.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordRESTInboxEvents.swift).
Relevant checks are [AccountReadStateModelTests.swift](../../App/Tests/SakuraCordAppTests/AccountReadStateModelTests.swift),
[InboxTests.swift](../../App/Tests/SakuraCordAppTests/InboxTests.swift) and
[InboxContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/InboxContractTests.swift).

## Acknowledgement authority

READY read state and versioned Gateway acknowledgements are authoritative across
launches. Do not persist a second local read boundary. Ordinary viewing ACKs require
the actual visible conversation/read geometry, not row construction or a temporary
pre-position viewport. The UI's visit boundary can remain stable while provider
acknowledgements advance in the background.

A visit acknowledges when the bottom edge of the newest message enters the
viewport, even if the first unread row of a long backlog is not loaded (a
lower-bound `N+` count). Opening such a backlog directly at its newest message
shows only its tail, so, as in Discord, that visit stays unread until the reader
scrolls toward the newest message again or chooses Mark as Read. Opening above
the newest message needs no extra gesture, and a fully visible unread run with
a loaded divider acknowledges on open.

A channel ACK posts to `/channels/{channel}/messages/{message}/ack` with applicable
flags, `last_viewed` and the latest server-issued token. Serialize account requests
and coalesce per channel; retain each optimistic intent's rollback boundary.
Definite failure reverts that intent without undoing an earlier accepted ACK.
Reconnects overlay pending intent rather than cancelling it. No automatic replay
follows an ambiguous failure.

Explicit Mark Unread uses the preceding message boundary with `manual:true` and
recomputed mention count. **Inbox Undo is different:** it sends an ordinary ACK
to the captured old boundary, preserving `last_viewed` and omitting `manual` and
`mention_count`. A strictly newer account read-state version can therefore move
the boundary backwards without `manual`. Older versions are ignored; equal-version
ordinary updates do not gain that authority. A pending Undo's exact target must
survive a preceding read ACK arriving late. Do not impose unconditional monotonicity.

## Unread groups and bulk actions

Opening/refreshing Unread freezes group order and message boundaries. New messages
do not append to that frozen range; edits/deletions reconcile existing entries.
Groups page history forward from the captured old boundary. Forum groups use post
IDs and the live thread catalogue. A normal Mark Read targets the captured newest
boundary; bulk operations capture targets before batching `/read-states/ack-bulk`.
Do not recompute targets from a later rerender or restore obsolete mention counts
on Undo. Fully loaded expanded empty groups may acknowledge and disappear without
Undo; incomplete loads do not establish emptiness.

Restricted groups require the applicable account eligibility and local server
consent before exposing their contents. Mentions also gate restricted accessories.
Bookmark and Reminder surfaces are outside this Inbox implementation.

## Recent mentions

`GET /users/@me/mentions` uses `limit=25`, role/everyone filters, optional guild
scope and an exclusive `before` cursor from the last **raw** response entry.
Filtered presentation must not change cursor advancement.

`DELETE /users/@me/mentions/{message}` and `RECENT_MENTION_DELETE` remove recent
mentions. They do not ACK a channel or clear its badge. Conversely, a channel ACK
does not remove recent mentions. Local filter choices are not server settings.

## Scheduled events

READY read-state type 1 uses a guild resource ID, last acknowledged event ID and
badge count. Individual event-group ACK is `POST /guilds/{guild}/ack/1/{event}`
with `{}`, reconciled through `GUILD_FEATURE_ACK`. Undo after fully acknowledging
an event group restores its card locally; it sends no reverse ACK.

Interest reads use `/users/@me/scheduled-events?guild_ids={guild}`. RSVP uses
PUT/DELETE `/guilds/{guild}/scheduled-events/{event}/users/@me`, with
`{"response":1}` for PUT. Event creation/update/deletion and user RSVP dispatches
update provider state; these are implemented consumers, not ignored families.

## Settings and notifications

Inbox tab/collapse settings use the shared type-1 protobuf writer and preserve
unknown fields. A `400 / 50105` invalid-data rejection reloads settings and reports
the failed write. Event collapse uses Discord's reserved channel key inside a
**guild-scoped** map; that key must not merge unrelated guilds. Rapid tab and
collapse changes are coalesced and only values that differ from saved settings
are written, one request at a time. An open Inbox keeps its local choices over
settings echoes; a failed collapse write restores the saved state.

Notification decisions use decoded mention IDs, roles and reply metadata, not
text parsing. Resolve channel/category/guild settings, mute expiry and account
preferences together with current access and foreground state. Native notification
delivery and Dock/sidebar presentation consume account read state; they must not
become independent read-state stores. Clear related native notifications when
confirmed read state requires it. OS delivery/audio verification is described in
[Development](../DEVELOPMENT.md#verifying-native-notification-audio).
