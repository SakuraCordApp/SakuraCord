# Friends and relationships

[Protocol index](../PROTOCOL_BASELINE.md)

## Owners and checks

| Contract | Source | Representative checks |
| --- | --- | --- |
| Records, full read, mutations | [DiscordRESTRelationships.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordRESTRelationships.swift) | [RelationshipContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/RelationshipContractTests.swift) |
| Friends projection | [FriendsState.swift](../../App/Sources/SakuraCord/Models/FriendsState.swift); [AppModelFriends.swift](../../App/Sources/SakuraCord/Models/AppModelFriends.swift) | [FriendsListPolicyTests.swift](../../App/Tests/SakuraCordAppTests/FriendsListPolicyTests.swift) |
| Ignore presentation and group warning | [IgnoredUsersState.swift](../../App/Sources/SakuraCord/Models/IgnoredUsersState.swift); [DiscordRESTProviderChannelState.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordRESTProviderChannelState.swift) | [IgnoredUsersTests.swift](../../App/Tests/SakuraCordAppTests/IgnoredUsersTests.swift); [RelationshipContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/RelationshipContractTests.swift) |

Reference: official stable 633029 (FriendsStore, RelationshipStore and the
relationship action modules), observed against the first-party client in
October 2026. Pinned Paicord agrees on routes and types; its older accept body
and CAPTCHA delivery are superseded. Pinned Swiftcord has no equivalent.

## Records and loading

Types are 0 none, 1 friend, 2 blocked, 3 incoming, 4 outgoing and 5 implicit.
Type 0 must be retained when `user_ignored` is true. READY
lists every record, sometimes without an embedded user; a record keeps its
identity until the user hydrates. READY_SUPPLEMENTAL `merged_presences.friends`
and private `PRESENCE_UPDATE` feed the shared private presence cache; absent
presence and another user's Invisible both read as offline. There is no
per-friend presence request.

`GET /users/@me/relationships` runs at most once per Gateway connection, started
by the first All or Pending view; Online and Add Friend use READY. A record
changed by Gateway or a successful nickname save while the read is in flight
keeps its newer state. Embedded users cannot overwrite a newer cached identity.
A new READY discards the result and replaces the app’s Friends projection.
Returning to All or Pending after reconnecting starts the eligible full read.

Cached user changes republish hydrated relationships in a coalesced update so
names, avatars, sorting and search follow live identities. Relationship changes
also refresh derived blocked/ignored sets, forwarding suggestions and retained
Inbox mentions. Blocking filters the retained pages without deleting messages,
so unblocking restores older mentions without restarting pagination.

`RELATIONSHIP_ADD` keeps stored nickname/since/note when omitted or null; `RELATIONSHIP_UPDATE`
replaces them; `RELATIONSHIP_REMOVE` deletes the relationship but retains a
type-0 Ignore record when `user_ignored` is explicitly true. Mutations answer 204
without a body and Gateway often arrives first, so responses never write records.

## Mutations

| Action | Request | `X-Context-Properties` location |
| --- | --- | --- |
| Send request (Add Friend form) | `POST /users/@me/relationships` `{"username":…,"discriminator":null}` (legacy tag: number), optional `note` | Add Friend |
| Send request (profile, DM or user menu) | `PUT /users/@me/relationships/{user}` `{}` | initiating surface, as for Ignore |
| Accept | `PUT /users/@me/relationships/{user}` `{"confirm_stranger_request":false}` | Friends |
| Remove, cancel, decline | `DELETE /users/@me/relationships/{user}` | Friends |
| Block | `PUT /users/@me/relationships/{user}` `{"type":2}` | ContextMenu |
| Unblock | `DELETE /users/@me/relationships/{user}` | none |
| Ignore | `PUT /users/@me/relationships/{user}/ignore`, omitted body | initiating surface |
| Unignore | `DELETE /users/@me/relationships/{user}/ignore`, omitted body | initiating surface |

Each is one attempt. Code 80013 on accept asks the user to confirm; only that
confirmation repeats it with `true`. Codes 80000–80007, 30002, 30059 and
30078 show Discord's copy and stay operation-scoped. Code 80013 on a send
shows no alert: the Add Friend form shows the generic username error inline,
and profile, DM and menu sends stay silent. Account restrictions also fail the
action without stopping unrelated traffic: 40002 asks the user to claim the
account and verify their email, and 40068 or any 4xx code in 340000–349999 reads “Your account has limited access”.
On a send, every other failed status, including 404 and 5xx, shows the generic
“Double check that the username is correct” copy instead of a transport error.
A failed send shows an alert titled “Friend request failed” beside any inline
text. A 404 DELETE means another session already removed it. Bulk pending clears, game relationships and
suggestions are not implemented.

Add Friend trims, drops one leading `@` from an untagged name and accepts
Discord's username pattern or a legacy `name#0000` tag, at most 37 characters.
Personalized requests accept an optional note, limited to 120 UTF-16 code units
before normalization. Newlines become spaces, surrounding whitespace is trimmed,
and an empty result is omitted from the POST body. The original normalized note
is retained through CAPTCHA replay. Both READY and live relationship events
carry the note; full reads use the same decoder. Pending shows outgoing notes
and reveals incoming notes on “View Request”, a local action with no REST call.
The note is request metadata, separate from the account's private user note.
Acceptance causes Discord to emit a DM `MESSAGE_CREATE` of type 67 containing
the note; the client must not send a duplicate message. This was observed when
accepting a personalized request in SakuraCord and in the official client.

These note contracts were observed in both saved accounts on 2026-10-08 against
the same official stable build, with module237309 supplying the UTF-16 validation
and normalization rules. Notes and their reveal state remain in session memory
and clear on account teardown.

## CAPTCHA

Send, accept, block, cancel and Ignore are challenged most often and follow the
shared [Human CAPTCHA](../PROTOCOL_BASELINE.md#human-captcha) contract. The
replay keeps the request's surface context and note. A repeated, failed or
dismissed challenge shows that action's usual failure copy, except that a
friend request send whose challenge the person closed ends silently with the
form unchanged: its usual copy blames the username.

## Ignore

Verified through the official macOS client on 2026-10-10: host 0.0.411,
web stable **634304**, build hash `17e01cf978c3c10a5688429a38db59a4926e8982`.
Live UI recordings used two authorized accounts. The loaded first-party
RelationshipStore (module994500), Ignore menu (module399476), notification
filters, and message construction supplement the captures. These are evidence
versions, not values to hardcode into runtime client metadata.

Ignore and Unignore use the dedicated `/ignore` subresource above. Both return
204 with an empty response and send no JSON body. Recorded context locations:
`DMUserContextMenu`, `GuildChannelUserContextMenu`, `user profile overflow menu`, `user settings`, and
`UserProfileRemediatedNotice`. The shared menu's source default is `ContextMenu`.
Responses do not write relationship state; a Gateway update can arrive before
or after the response. No repeated mutation or synthetic relationship deletion
is needed. No live CAPTCHA or rate-limit response occurred in these recordings.

`user_ignored` is independent of type. Live transitions included friend →
ignored friend → ignored non-friend → ignored outgoing request → blocked with
Ignore retained → ignored non-friend → ignored incoming request → ignored
friend. Removing a friendship and unblocking emitted `RELATIONSHIP_UPDATE`
with `type:0,user_ignored:true`. Accepting preserved Ignore. Block takes
presentation precedence while retaining the underlying flag. Reload must retain
non-friend Ignore records, including records whose identity is not yet hydrated.
The current source also preserves Ignore on a removal event explicitly carrying
`user_ignored:true`.

Observed presentation: consecutive ignored messages collapse into revealable
runs; reveals do not mutate the relationship and reset on client reload.
Profiles require a local reveal. The composer remains usable, and a DM sent
while ignoring its recipient is delivered normally. Incoming content remains
collapsed. Ignore does **not** mark DMs read. Incoming ignored requests are
excluded from Pending, but can be accepted through a revealed profile. Unignore
restores content without refetching or deleting retained history. Settings lists
ignored accounts separately from blocked accounts.

Settings management was verified through the official client on 2026-10-29
(web stable **653945**). Messaging Permissions → Ignore & Block lists both from
the relationships already held by the client; opening it sends no relationship
request. A blocked account that is also ignored appears only under blocked.
Unblock and Unignore act immediately, without a confirmation. Unblock sends the
context-free DELETE above. Unignore sends the `/ignore` DELETE with location
`user settings`. SakuraCord's Privacy settings link to searchable Blocked
Accounts and Ignored Accounts lists with the same actions.

Source-backed rules extend suppression to messages whose command initiator is
ignored, and to reply previews, typing, activity, mention suggestions, message
notifications and incoming-call alerts. Guild voice joins with ignored participants
warn rather than silently block joining. A live direct-call check received ring
events and retained the inline join control; joining did not show an Ignore warning.
The guild warning was live-tested with Cancel and Join; SakuraCord also verified
its post-join Stay action and pre-join Cancel/Join Anyway actions. Both accounts
connected muted. Revealed ignored messages also accepted reactions
and replies, and a received mention remained collapsed. The app keeps relationship data with
the provider, per-account reveal state with `IgnoredUsersState`, management
with the shared user menu and Privacy settings, and collapsed content with the
shared native timeline. Copy actions remain grouped and consequential actions
remain last. No Active Now surface is added.

Opening a group DM containing an ignored recipient shows an informational warning.
The official “Don’t leave” action sends `POST /channels/{channel_id}/blocked-user-warning-dismissal`, with no body or context
header, and receives 200 with an empty body. This acknowledgement is independent
of Ignore and of group membership. `blocked_user_warning_dismissed` on channel
records suppresses future warnings. SakuraCord uses its native Continue alert
and sends one acknowledgement, retaining the existing group. Failure stays
visible and makes acknowledgement eligible again on reopening. Per-session
warning/reveal state clears on account teardown.

Private action-linked captures, screenshots, restoration notes, and the full
verification matrix stay outside Git. Distinguish live observations from source
rules and deterministic checks when reporting coverage; neither forced server
errors nor permission/entitlement combinations unavailable to the test accounts
should be described as live-tested.
