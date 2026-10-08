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

Supported invite and discoverable-server join hCaptcha retains the original
body/context and permits one replay after human completion on the same provider and Gateway session. Empty
solutions, cancellation, account replacement, another challenge or ambiguous
failure terminate that attempt. Unsupported/malformed challenges and account
restrictions retain the session safety circuit. Widget test-token verification does not establish successful handling of a live
join CAPTCHA.

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
