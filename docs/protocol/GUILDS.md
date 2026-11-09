# Guilds and membership

[Protocol index](../PROTOCOL_BASELINE.md)

## Owners and checks

| Contract | Source | Representative checks |
| --- | --- | --- |
| Invite preview/join/leave | [DiscordRESTServerInvites.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordRESTServerInvites.swift) | [ServerInviteContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/ServerInviteContractTests.swift); [HumanCaptchaTests.swift](../../App/Tests/SakuraCordAppTests/HumanCaptchaTests.swift) |
| Join applications | [DiscordRESTGuildJoinRequests.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordRESTGuildJoinRequests.swift); [AppModelGuildJoinRequests.swift](../../App/Sources/SakuraCord/Models/AppModelGuildJoinRequests.swift) | [ServerInviteContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/ServerInviteContractTests.swift) |
| Onboarding/customization | [DiscordRESTOnboarding.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordRESTOnboarding.swift); [AppModelGuildCustomization.swift](../../App/Sources/SakuraCord/Models/AppModelGuildCustomization.swift) | [OnboardingContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/OnboardingContractTests.swift); [GuildCustomizationTests.swift](../../App/Tests/SakuraCordAppTests/GuildCustomizationTests.swift) |
| Guide | [DiscordRESTGuildGuide.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordRESTGuildGuide.swift); [AppModelGuildGuide.swift](../../App/Sources/SakuraCord/Models/AppModelGuildGuide.swift) | [OnboardingContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/OnboardingContractTests.swift) |
| Catalogues and members | [Gateway request builders](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordGatewaySupport.swift) | [ServerProviderContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/ServerProviderContractTests.swift); [GatewayLifecycleEventTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/GatewayLifecycleEventTests.swift) |

## Invites

Preview is a read of `/invites/{code}`. Acceptance is an explicit POST to that
route with the current Gateway session and correct Join Guild or invite-embed
context. Message-card acceptance also supplies its invite-instance identity.
Preserve the preview when a sparse acceptance response omits enrichment.
`GUILD_CREATE` can arrive before or after the REST result; neither order may lose
membership. Already-member cards navigate without posting another acceptance.
Leaving is `DELETE /users/@me/guilds/{guild}` with `lurking:false`; guild owners
cannot use it. `GUILD_DELETE unavailable:true` is an outage, not a leave.

Invite and discoverable-server joins follow the shared
[Human CAPTCHA](../PROTOCOL_BASELINE.md#human-captcha) contract. The replay keeps
the body, including its Gateway `session_id`, and context, and is cancelled if
that session is no longer current. Ambiguous failure is never
replayed. Unsupported/malformed challenges and account restrictions report a
join error without stopping unrelated account traffic.

Onboarding invites can enter the native membership flow. Apply-to-join and
member-screening invites open the [application form](#join-applications).
Special guest/target flows remain delegated to Discord. Unknown catalogue or
verification state must not be reported as completed joining. A successful
membership does not require a readable channel.

Created invite links are user-requested mutations with explicit options. Cached
links are account-scoped, expire locally and are checked before reuse; they are
not evidence of membership or authorization. Use the provider request builders
for exact create/delete fields rather than extending preview behaviour implicitly.

## Server tag cards

An explicit profile tag opens `GET /guilds/{guild}/profile` without query or body.
Validate the returned guild identity. `403` / `50001` means a private profile;
`404` is expected. Neither stops account networking. The Guide shares this profile.
The title badge represents server status, not the custom `badge_hash` from its tag.
Staff, verified and partnered features take priority; other Community servers use
a globe when discoverable or a house otherwise. Positive subscription count or
premium tier adds the boost tint only to those Community badges. Discovery banners
are shown only for `DISCOVERABLE` guilds. Resolve the five top `game_application_ids`
through the existing games provider after ranking by `game_activity.activity_score`.

Existing members navigate without joining. Without an invite, Join is offered only
for discoverable guilds. A profile with `visibility:3` plus screening and
manual-approval features offers Apply to Join instead, or View Application Status
while the account has an application under review; see
[join applications](#join-applications).
SakuraCord has no lurker mode: it sends the final full-membership
`PUT /guilds/{guild}/members/@me?lurker=false` with `{}` and
`X-Context-Properties: e30=`. This has one attempt and at most one human-completed
CAPTCHA replay on the same provider/Gateway session. Banned/server-limit responses
remain operation-scoped; Gateway membership reconciliation confirms completion.

Live first-party build `630444` on 6 October 2026 confirmed profile reads and the
Go to Server / Join / no-action states for joined, unjoined discoverable and
unjoined non-discoverable servers. Status-badge precedence also follows that
build’s public GuildBadge implementation. Hidden-profile errors and actual joins
were not exercised in that live pass.

The join request construction was established by first-party web build `622805` static
analysis on 29 September 2026. Paicord has only the PATCH member route and pinned
Swiftcord has no equivalent. No live join was performed. The provider request and
budget coverage lives in `ServerInviteContractTests`.

## Join applications

A guild with both `MEMBER_VERIFICATION_GATE_ENABLED` and
`MEMBER_VERIFICATION_MANUAL_APPROVAL` is apply-to-join: a moderator must approve
an application before the account becomes a member. Each account has at most one
request per guild. Its `application_status` is `STARTED`, `SUBMITTED`, `REJECTED`
or `APPROVED`; a request carries `id` (also `join_request_id`), `guild_id`,
`user_id`, `rejection_reason`, `interview_channel_id`, `created_at`,
`reviewed_at` and `last_seen`.

Applicant sequence, as the official client performs it:

1. The invite POST (see [Invites](#invites)) answers `show_verification_form:true`
   and creates or reuses a `STARTED` request; no membership or `GUILD_CREATE`
   follows. Opening the invite again while `SUBMITTED` or `REJECTED` shows that
   request's status instead of the form.
2. `GET /guilds/{guild}/member-verification?with_guild=true&invite_code={code}`
   returns `version`, `description`, `form_fields`, `guild` and `profile`.
3. `PUT /guilds/{guild}/requests/@me` with `{version, form_fields}` and no
   `X-Context-Properties` submits. Each field is echoed as received plus
   `response`: a string for `TEXT_INPUT` (at most 150 UTF-16 code units, the
   input's `maxLength`, which truncates longer input) and `PARAGRAPH` (1,000,
   newlines kept), the zero-based choice index for `MULTIPLE_CHOICE`, and
   `true` for `TERMS`. The response is `201` with the `SUBMITTED` request.
4. Withdrawing is `DELETE /guilds/{guild}/requests/@me` (`204`). Reapplying after
   a rejection is `POST /guilds/{guild}/requests/@me` without a body, which
   replaces the old request with a new `STARTED` one before the form opens again.
5. Closing the approval greeting sends `POST /guilds/{guild}/requests/{id}/ack`;
   it sets `last_seen`, after which the applicant view ignores the approval.

`/users/@me/join-request-guilds` names the guilds (id, name, icon, features) the
account has applied to, which are not in its guild list. READY's
`guild_join_requests` lists the account's requests without answers. Gateway
`GUILD_JOIN_REQUEST_CREATE`/`UPDATE` carry `{guild_id, status, request}` and
`GUILD_JOIN_REQUEST_DELETE` carries `{guild_id, id, user_id}`; moderators also
receive other people's requests, so the applicant state ignores any whose
`user_id` is not the current user. The Gateway update can precede the HTTP
response. Withdrawing, reapplying and leaving the guild after approval each
delete the previous request. Approval adds the guild through the ordinary
`GUILD_CREATE`, after which onboarding applies as for any join.

Moderator review uses `GET /guilds/{guild}/requests?status=SUBMITTED&limit=…`,
`GET /guilds/{guild}/requests/users/{user}` and
`PATCH /guilds/{guild}/requests/{id}` with `{action:"APPROVED"}` or
`{action:"REJECTED", rejection_reason}` (the reason is optional and omitted when
empty). Interview is `POST /join-requests/{id}/interview`, which creates a group
DM whose id equals the request id, with channel flag `65536`; approval then posts
a system message of type 52 there. SakuraCord does not implement review or
editing the form; those remain in Discord.

Applying from a guild profile reads the form without an invite code, and the
submitting `PUT /guilds/{guild}/requests/@me` creates the application. Without an
invite, both the full-membership `PUT /guilds/{guild}/members/@me` and the
Reapply `POST /guilds/{guild}/requests/@me` answer `404` (observed 8 November
2026). Member screening without manual approval (gate feature
only) admits the account as a pending member (`pending:true`); it submits the
same form through the same `PUT`, and Discord clears `pending` with a member
update. Like Discord's input blocker, a pending member's conversation offers
Complete in place of the composer.

Like the official client, SakuraCord groups the account's unapproved requests to
servers it is not in (`STARTED`, `SUBMITTED` and `REJECTED`) in a Pending
Applications rail folder; selecting one replaces the workspace with its status.
An unsubmitted application offers Open Application and Discard Application (the
same `DELETE` as Withdraw); a rejected one shows the reason and offers Reapply and
Withdraw. Submitting leaves the current view in place, opens the folder and points
at it with "Your application is pending!". The form and the approval greeting are
modals. SakuraCord also lets the applicant view the
submitted answers, read with `GET /join-requests/{id}`, which Discord returns to
the applicant; the official client shows them only in an interview. The interview's
type 52 message renders as the approval notice. Unknown field types (Discord also
defines `VERIFICATION`) cannot be answered here, so their application must be
completed in Discord. Writes use the ordinary single-attempt mutation budget.

Official Fresh host `0.0.411`, web build `667580`, observed on 8 November 2026
with the same server and accounts, confirmed the submission without
`X-Context-Properties`, the 150-unit truncation of a pasted answer, the kept
paragraph newline in the request (Discord stores the answer without it, for its own
submissions too), rules-only screening's "Before you can talk here…" form, the
folder and "Membership Incomplete" status of a `STARTED`
request after Reapply, Open Application (which reads the form again with the
remembered `invite_code`), Discard Application, and the pending note after
submitting.

Official Fresh host `0.0.411`, web build `660103`, observed on 3 November 2026
with a test server switched to apply-to-join and a second account, confirmed the
sequence above: every field type, required-field and length limits, closing an
unsubmitted form (no request is sent; the `STARTED` request remains), submit,
withdraw, reapply after withdrawal and after rejection (no cooldown), rejection
with and without a reason, interview, approval, leaving after approval and an
already-member invite (which still posts the invite and then navigates). The
form editor only offers required questions; `required:false` handling follows
the same build's form code. Applying from the guild profile and rate-limit (`429`)
and ineligible (`150023`) rejections were not exercised live.

## Onboarding and channel selection

Configuration comes from `/guilds/{guild}/onboarding`; initial answers POST to
`onboarding-responses`, later edits PUT. Welcome/member state and the existing
Gateway member query determine completion. READY's self-member records must be
available for every guild before deciding whether onboarding is needed. Unknown
membership means loading, not unfinished onboarding. Screening independently
gates sends, threads, forum creation and retries.

Choices live in the account's feature store. Restore them across navigation only
while join identity and confirmed answers still match; prune removed options.
Initial navigation through questions is local until submission. Post-join edits
are debounced and serialized per membership. A confirmation updates the baseline
without erasing newer input. After failure, read back before rolling back because
the write may have reached Discord. Optimistic roles never grant permissions.

Channel selection overlays only the relevant opt-in/favourite bits, preserving
unrelated notification settings. Category inheritance and individual choices are
distinct from Discord access permissions. Selected channels and channels with
mentions remain discoverable under the applicable filtering rules.

**Settings → Features → Channel customization** is a local preference. Off shows
all accessible channels and hides channel browsing/selection controls; applicable
role questions and required onboarding remain available. It does not erase saved
server choices or mutate Discord. Discord's separate Show All Channels setting
changes server-side filtering without erasing individual selections. Community
guilds with prompts expose Channels & Roles; those without use Browse Channels
when local channel customization is enabled. Voice/Stage channels use the same
selection policy, not an independent expansion state.

### Hide muted channels

The server context menu's Hide Muted Channels is the account's synchronized
per-guild `hide_muted_channels` setting, independent of Show All Channels and the
local channel-customization preference. Each user action sends one
`PATCH /users/@me/guilds/settings` with
`{"guilds":{"<guild_id>":{"hide_muted_channels":true}}}` (or `false`). It changes
no notification levels, mute state, channel selections or flags. The ordinary
single-attempt mutation budget applies; errors retain the previous setting.
READY and `USER_GUILD_SETTINGS_UPDATE` supply the same field to every session;
the Gateway update can precede the HTTP 200 response. Merge sparse settings
updates without discarding unrelated overrides.
The app's successful-request fallback must not overwrite authoritative settings
received while that request was pending, including a newer change from another
client or a replacement READY. Unrelated local override edits retain the fallback.

When enabled, hide directly muted channels except the selected conversation,
connected voice channel, selected thread's parent, channels with mentions, or
parents with visible joined threads. Apply the existing thread relevance and
muted-thread rules before deciding whether to keep a parent. Guild and category
mutes do not count as direct channel mutes for this filter; category collapse
continues to control its rows separately. Expired timed mutes stop hiding a
channel even without another Gateway event. Empty filtered groups disappear.
Ordinary next/previous channel shortcuts traverse the same filtered rows.
Browse Channels continues to list muted channels and preserves their channel
selection independently of mute state. Its ordinary channel context menu offers
Unmute Channel even while the sidebar hides the row. Previewing a muted channel
there does not reveal it in the sidebar; opening it as the main conversation
does. Quick Switcher and temporarily disabling Hide Muted Channels provide other
ways to reach a hidden channel without changing its saved channel selection.

Official Fresh host `0.0.411`, web build `641004`
(`web.4d4b2f75fdea5470.js`), observed on 17 October 2026, confirmed the partial
toggle PATCH, HTTP 200 settings response, Gateway echo, and hide/reveal of a
directly muted channel with Show All Channels enabled. Live changes in either
Discord or SakuraCord updated the other session without a reload; temporary
settings were restored. The selected muted channel remained visible until
navigating away. The same build's channel list and guild-settings store establish
the remaining focus, mention, joined-thread and direct-mute exceptions. Those
exceptions are source evidence rather than a claim that every branch was
exercised live.

Pinned Paicord `5c76f3674e2cace7a6a4369497fcf482f3d9ebe3` hydrates its
[guild-settings store](https://github.com/llsc12/Paicord/blob/5c76f3674e2cace7a6a4369497fcf482f3d9ebe3/Paicord/Stores/UserGuildSettingsStore.swift)
from READY without consuming later guild-settings events there. Swiftcord v1
`14465d927ebe1ba34b3befa00f9365fad7b56eb9` has no equivalent filter in its
[channel list](https://github.com/SwiftcordApp/Swiftcord/blob/14465d927ebe1ba34b3befa00f9365fad7b56eb9/Swiftcord/Views/Server/ChannelList.swift).

## Server Guide

Guide entry reads `new-member-welcome`, optional guild profile enrichment and
`new-member-actions`. A task records `POST /guilds/{guild}/new-member-action/{channel}`
with no body. Guide configuration PUT observed during research does not establish
an app editing surface.

Visibility depends on the applicable guild capabilities plus resources or
unfinished introductory tasks within the first seven days, not one feature flag
alone. Progress is separate from onboarding and screening. Confirm guild/member
identity on task responses; an empty progress result must not undo confirmed
`COMPLETED_HOME_ACTIONS` membership state.

Opening Guide or a resource is read-only. A visit task completes only after its
explicit navigation/history succeeds; a send task waits for a confirmed own
message. Resource previews do not complete tasks. Read resources from the beginning
of channel history through the existing provider and renderer, without a composer.
There is no established dedicated per-task Gateway progress event; refresh and
member flags supply reconciliation.

## Guild and member lifecycle

Keep raw guild/channel/role metadata sufficient to recompute permissions after
updates. Unavailable guilds retain state; ordinary deletion removes guild-scoped
state. Sparse updates preserve absent values. Permission changes must affect
retained conversations and searches without requiring a channel-list reload.

Use bounded member subscriptions/searches through the Gateway owner. Cache
identities separately from message bodies; member-list presentation should neither
scan history nor create a REST fan-out. Full profile reads are explicit/coalesced
and are not a substitute for guild member state. Check current access before
publishing a cached channel or member result after asynchronous work.
A member-list `INVALIDATE` keeps the last known rows only while the list's channel
is still accessible and resolves to the same list; otherwise the rows are cleared.
Each `SYNC` replaces its declared range, clearing unfilled positions when fewer
items arrive while preserving cached rows outside that range.
SakuraCord marks each retained or requested list with an overlapping `INVALIDATE` for refresh:
the selected list is re-sent at once, others on their next viewport report. Member
and thread subscription sends are serialized per guild. A completed send satisfies
only the refresh generation captured before that send and cannot erase a newer
invalidation. Refreshes read the latest requested viewport when their send begins,
including a viewport that could not be committed during a cooldown. Invalidation
overlap and opcode-37 rejection recovery include requested ranges whose send has
not committed yet, including an active send after selection moves to another
list; those sends cannot satisfy a newer refresh marker.
Access-driven queue resets restore the current accessible requested viewport,
adopting a viewable channel's changed member-list identity;
selection changes and session/guild teardown prevent delayed restoration.
That restoration waits out an already-known opcode-37 cooldown before its one
attempt, including when the requested list has not yet committed a subscription.
An inaccessible viewport supersedes the prior selection without sending a
subscription. Returning to an accessible retained list republishes its cached
rows even when its ranges are unchanged; a purged shared-list alias requires a
fresh subscription.
Gateway resume restores the selected channel's latest requested ranges instead
of resetting a scrolled member list to the first block. A fresh `READY` clears
that viewport with the session snapshots and starts from the initial block.
Member-only queue resets preserve a pending readable thread subscription and
requeue it under the current generation. Request ownership prevents an older
failure from removing a successor's desired thread. Closing/archiving a thread,
eviction, account/guild teardown, and cancellation remain terminal; transport
failures and cooldowns do not trigger this local-generation repair.

For a known opcode-37 cooldown, SakuraCord makes at most one deferred attempt
for the selected refresh, including a requested list whose first send has not
committed, canceled on selection, access loss or session/guild teardown.
Waiting timers and queued refreshes canceled before their send begins do not
consume that attempt budget. An asynchronous `RATE_LIMITED` restores the refresh
marker; a rejected deferred attempt does not start a retry loop. Further failure
keeps the marker for a later viewport action or reconnect. These bounds are
SakuraCord's recovery policy.

The public [Gateway rate-limit contract](https://docs.discord.com/developers/events/gateway-events#rate-limited)
defines `opcode` and `retry_after` in seconds, with guild metadata documented
for opcode 8 only. Opcode-37 recovery therefore accepts absent guild metadata
and conservatively marks accessible subscribed or requested lists. This is not
evidence that Discord supplies guild metadata for opcode 37.
Official client host 0.0.411, web build 634304, inspected on 2026-10-13,
uses opcode 37 for channel-range and partial thread subscriptions. A captured
`SYNC` declared `[0,99]` with four members and two group rows, confirming that
the returned items can be shorter than the declared range. No `INVALIDATE` or
opcode-37 `RATE_LIMITED` was observed in that verification. Its static member
store clears invalidated rows; retaining accessible rows and explicitly renewing
them is SakuraCord's deliberate presentation and recovery policy, covered by
Gateway-backed regression tests rather than a claimed live rejection capture.

### Server timeouts

`communication_disabled_until` belongs to guild membership, including READY's
self-member records, member-list/chunk payloads and `GUILD_MEMBER_UPDATE`. A future
ISO8601 timestamp restricts communication; null or a past timestamp does not.
Preserve an omitted field in sparse member updates, chunks, member lists and
thread hydration; explicit null removes the timeout. A full replacement READY is
authoritative. Account/guild teardown cancels local expiry work, and a replaced
timeout cannot be cleared by its older timer. Delayed member-load completions
must not replay an older timeout over a newer Gateway update. Member events
received before initial bootstrap publication must survive that publication.

Apply the timeout mask after channel overwrites: only existing `VIEW_CHANNEL`
and `READ_MESSAGE_HISTORY` survive. The mask does not grant access to hidden
channels. Owners and administrators are exempt. This follows Discord's
[permissions contract](https://docs.discord.com/developers/topics/permissions)
and [guild member field](https://docs.discord.com/developers/resources/guild#guild-member-object).
SakuraCord preserves drafts while showing the timeout countdown in its shared
disabled channel/thread input bar. Active voice-message capture stops and its
recording is retained for the same conversation. It blocks new and existing
reaction toggles, replies, sends, message edits, new poll votes,
thread/forum creation, application commands and joining voice. Read-only history
and reaction-detail inspection remain available. If thread creation succeeds
before a timeout blocks its first message, retain the unsent text and attachments
in the created thread. Delivery checks include work
queued before a timeout and message-send retries after rate-limit suspension.
No new polling or mutation retry budget is introduced.

Official Fresh host `0.0.411`, web build `641004`
(`web.4d4b2f75fdea5470.js`), observed on 17 October 2026, sent one
`PATCH /guilds/{guild}/members/{user}` with the expiry timestamp, or null for
removal. Each returned HTTP 200, with a `GUILD_MEMBER_UPDATE` preceding the HTTP
response. The timed-out account showed a persistent countdown in place of its
composer, disabled existing reactions and a locked voice channel. The composer
returned at natural expiry without navigation/reload or another captured member
update. This observed absence is not a guarantee that Discord never emits one.
The same build's modules `316031`, `488926` and `592713` establish timestamp
comparison, the post-overwrite mask and local expiry invalidation. SakuraCord
schedules the actual expiry instead of Discord's ten-second cleanup interval.

Additional checks on the same build confirmed that timeout follows the member
across server channels and survives a client reload with a fresh READY, while DM
composers remain usable. The own-message menu still offered Edit and Delete, but
opening Edit produced a disabled input. SakuraCord keeps an already-open edit's
draft while disabling its input and Save. Poll answers could be selected locally,
but Vote remained disabled until removal; the same selection then submitted
successfully. Removing an existing vote remained enabled during timeout and
returned HTTP 204 with `answer_ids: []` on the same poll PUT route. Result/voter
inspection is a read and remains available.
Existing reactions were disabled too, contrary to the existing-reaction exception
in Discord's [Timeout FAQ](https://support.discord.com/hc/en-us/articles/4413305239191-Time-Out-FAQ).
Follow the current client and permission contract rather than that FAQ sentence.
The built-in `/timeout` command replaced a running 60-second deadline with five
minutes using one member PATCH; the live countdown changed immediately and stayed
restricted past the original deadline. An unrelated profile/nickname response is
not authoritative timeout evidence for an already-cached member.

A two-account live pass against SakuraCord verified immediate application and
manual removal with channel and thread composers open, plus natural expiry
without navigation or reload. Both drafts survived each transition. Existing
reaction controls were disabled during the timeout; sending and reacting worked
after removal. SakuraCord's sanitized API log recorded the member updates,
message HTTP 200 and reaction HTTP 204, compared with the official client's
Gateway capture. Temporary timeout state, drafts and verification content were
restored or removed after the pass. A later native poll pass verified that an
existing vote could be removed during timeout (HTTP 204), a locally selected
replacement could not be submitted, and live removal enabled Vote with that
selection intact. The disposable poll was deleted and timeout removal confirmed.

Pinned Paicord `5c76f3674e2cace7a6a4369497fcf482f3d9ebe3` decodes the field but
its [member merge](https://github.com/llsc12/Paicord/blob/5c76f3674e2cace7a6a4369497fcf482f3d9ebe3/Paicord/Utilities/PaicordLib%2B%2B/Merging.swift)
uses nil-coalescing, which does not establish correct removal via explicit null.
Swiftcord v1 `14465d927ebe1ba34b3befa00f9365fad7b56eb9` has no equivalent
timeout consumer. Neither supplies a competing timeout presentation contract.

### Thread member inspector

Full-width public/private threads and forum posts use explicit thread membership,
not the parent channel's lazy member list and not the set of message authors.
The desktop client sends bulk Gateway opcode 37 with
`subscriptions[guild_id].thread_member_lists: [thread_id, ...]`, retaining at most
three thread lists per guild. Other subscription fields are partial updates;
adding a thread must not erase existing channel ranges. Reconnect restores the
retained subscriptions; a fresh READY clears member snapshots before repopulating.

`THREAD_MEMBER_LIST_UPDATE` replaces the thread's member IDs. Its `members` entries
carry `user_id`, optional guild `member`, and optional `presence` records.
`THREAD_MEMBERS_UPDATE` adds/removes IDs; guild member, role, user, and presence
updates refresh their presentation. Keep the shared guild identity cache separate
from the per-thread membership set. Closing/archiving or deleting a thread removes
its member subscription. Announcement threads use the parent channel's member
list; archived threads show an empty member state instead of unrelated guild members.

Group online members by hoisted role, then Online, then Offline (including
Invisible). Within each group sort by lowercase guild display name, then user ID.
The current user's account status overrides the public presence record.

This user-client contract was observed on 2026-10-06 in Discord Official Fresh
host 0.0.411, `web.90d3ab34abfe98da.js`, including a decoded member-list event after
an opcode 37 subscription. Static first-party modules 63238 and 219065 establish
subscription retention and grouping. The public [thread documentation](https://docs.discord.com/developers/topics/threads)
corroborates explicit membership; its bot REST enumeration is not the desktop
member-inspector transport.

In the same test server, an official-client leave/rejoin produced
`THREAD_MEMBERS_UPDATE` removal/addition events and changed the open SakuraCord
inspector from one member to empty and back without navigation or reload.

Paicord revision `5c76f3674e2cace7a6a4369497fcf482f3d9ebe3` declares the optional
subscription field but its GatewayStore leaves it unset. Swiftcord v1 revision
`14465d927ebe1ba34b3befa00f9365fad7b56eb9` has no equivalent thread-member-list
consumer. These references do not supply a competing inspector implementation.
