# Guilds and membership

[Protocol index](../PROTOCOL_BASELINE.md)

## Owners and checks

| Contract | Source | Representative checks |
| --- | --- | --- |
| Invite preview/join/leave | [DiscordRESTServerInvites.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordRESTServerInvites.swift) | [ServerInviteContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/ServerInviteContractTests.swift); [HumanCaptchaTests.swift](../../App/Tests/SakuraCordAppTests/HumanCaptchaTests.swift) |
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

Onboarding invites can enter the native membership flow. Member screening and
special guest/target flows remain delegated to Discord. Unknown catalogue or
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
for discoverable guilds. Manual-approval recruitment (`visibility:3` plus screening
and manual-approval features) remains delegated to Discord, as does member screening.
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
