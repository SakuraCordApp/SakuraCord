# Profiles and synchronized settings

[Protocol index](../PROTOCOL_BASELINE.md)

## Owners and checks

| Contract | Source | Representative checks |
| --- | --- | --- |
| Profile saves and widgets | [DiscordRESTProfileSaving.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordRESTProfileSaving.swift); [DiscordProfileWidgetEligibility.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordProfileWidgetEligibility.swift) | [ProfileEditingContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/ProfileEditingContractTests.swift); [ProfileEditorStateTests.swift](../../App/Tests/SakuraCordAppTests/ProfileEditorStateTests.swift) |
| Nicknames | [DiscordRESTProfileSaving.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordRESTProfileSaving.swift); [DiscordRESTRelationships.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordRESTRelationships.swift); [AppModelNicknames.swift](../../App/Sources/SakuraCord/Models/AppModelNicknames.swift) | [NicknameCommandTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/NicknameCommandTests.swift) |
| Status | [DiscordProfileSettingsProto.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordProfileSettingsProto.swift); [DiscordRESTProfileCustomStatus.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordRESTProfileCustomStatus.swift) | [StatusPickContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/StatusPickContractTests.swift) |
| Server folders | [DiscordSettingsProtoMerging.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordSettingsProtoMerging.swift) | [GuildFolderSettingsContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/GuildFolderSettingsContractTests.swift) |
| Emoji usage and shared saves | [AppModelEmojiFrecency.swift](../../App/Sources/SakuraCord/Models/AppModelEmojiFrecency.swift); [DiscordRESTEmojiFrecency.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordRESTEmojiFrecency.swift) | [EmojiFrecencyTests.swift](../../App/Tests/SakuraCordAppTests/EmojiFrecencyTests.swift); [QuickReactionPolicyTests.swift](../../App/Tests/SakuraCordAppTests/QuickReactionPolicyTests.swift); [GIFProviderContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/GIFProviderContractTests.swift) |
| Favourites/frecency | [DiscordSettingsProtoStickers.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordSettingsProtoStickers.swift); [DiscordSettingsProtoSoundboard.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordSettingsProtoSoundboard.swift); [DiscordSettingsProtoCommandFrecency.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordSettingsProtoCommandFrecency.swift) | [ProviderRequestContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/ProviderRequestContractTests.swift); [GIFProviderContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/GIFProviderContractTests.swift); [ApplicationCommandFrecencyCodecTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/ApplicationCommandFrecencyCodecTests.swift) |

## Profile edits and private account data

The provider owns current eligibility and validation; the editor owns a draft.
Apply account/guild scope and permission checks at submission, not only while
showing controls. Profile saving is staged: keep failed or newer edits without
repeating acknowledged writes. File selection/cropping does not save a profile.
Widget assets use their allocated upload path before references enter the draft.

Personal widgets require their entitlement and rollout assignment. **Game widgets
do not inherit the personal-widget Nitro requirement.** Use the eligibility model
and widget type; do not apply one blanket gate to all widgets. Owned collectibles,
guild permissions and product-specific restrictions remain independent checks.

Account contact/device details are private session-only values. Do not add email,
phone or session hashes to public User values or saved-account labels. Profile
and own-user updates invalidate/reconcile the appropriate caches; late work from
a replaced account cannot publish into the new editor.

## Nicknames

Your own server nickname is edited in the per-server profile or with
[`/nick`](MESSAGING.md#forums-threads-and-commands). In a server, your user menu
offers **Edit Per-server Profile**, which opens Profiles on that server's scope.
For another member, **Change Nickname** follows Discord's `canManageUser`:
never the guild owner; the owner manages everyone else; anyone else needs
Manage Nicknames (or Administrator) and a highest role above the target's, by
`position` and then the older role ID, with @everyone last. Unloaded role
records are ignored within the low-level highest-role lookup, but Discord's
menu separately excludes missing members, guests and lurkers (`joined_at: null`).
Like its member subscription, SakuraCord starts a coalesced lookup through the
existing member provider when a menu target is missing. The action remains
hidden until the member store can establish membership and hierarchy; opening
then seeds the real nickname. Failed resolution offers no editable draft.
Administrators remain bound by hierarchy. Pending members and guests cannot
manage nicknames; non-administrators are also restricted during a timeout or AutoMod quarantine
(member flag 128, 256, or 1024). Guild owners bypass these member restrictions.
The dialog sends one `PATCH /guilds/{guild}/members/{user}` with
`{"nick":"value"}` as typed; Reset sends `""` and a value confirmed unchanged
in the current member store closes without a request. Missing member data never
turns an explicit reset into an unchanged-value shortcut. The member response
reconciles the store unless the target member has a newer revision in that guild
or the session has reset.
Updates in other guilds do not suppress the saved nickname. `nick` validation
errors stay in the dialog and `403` remains operation-scoped. No audit-log reason
is sent.

Friend nicknames are private to the account and offered only for friends
(relationship type 1): **Add Friend Nickname** or **Change Friend Nickname** in
server, thread, DM and group-DM user menus. Save sends one
`PATCH /users/@me/relationships/{user}` with the trimmed `{"nickname":"value"}`;
Reset or blank text sends `null`, and success is `204`. A `400` stays in the
dialog rather than opening the session safety circuit, and a result that returns
after a session reset or a newer event for that friend does not replace that state.
Events for other friends do not suppress the saved nickname. READY
`relationships[].nickname` seeds the map. `RELATIONSHIP_ADD` sets a non-null nickname, `RELATIONSHIP_UPDATE`
replaces it (null or absent clears) and `RELATIONSHIP_REMOVE` deletes it.

Names follow Discord's `getNickname(guild, channel, user)`: servers use only the
server nickname; DMs and group DMs use the friend nickname before the global
name. The provider applies it to unnamed DM and group-DM titles, private members
and DM typing; the app applies it to private message authors, mentions,
notifications and profiles opened outside a server. Group-DM `nicks` are neither
shown nor editable, as in the official client.

These contracts come from static analysis of first-party web build `630444`
(`web.90d3ab34abfe98da.js`) on 7 October 2026: the Change Nickname modal and
menu item, `canManageUser`, the friend-nickname modal, menu and request,
RelationshipStore, and name resolution. The public
[Modify Guild Member](https://docs.discord.com/developers/resources/guild#modify-guild-member)
route corroborates the member request. Pinned Paicord declares the same
relationship PATCH without a UI; Swiftcord v1 has no equivalent.

A live server-member check on 8 October 2026 (desktop 0.0.411,
`web.d3978f1210c00a8f.js`) confirmed the official moderator action sends
`PATCH /api/v9/guilds/{guild}/members/{user}` with `{"nick":"value"}` and returns
the member with HTTP `200`. Its `GUILD_MEMBER_UPDATE` updated SakuraCord without
a reload. Reset from SakuraCord produced `nick: null` in the independent
official session and restored both member lists without a reload. Existing
owner and second-account menus matched in both clients: the owner could rename
the target; the second account had no action for the owner or the other member
checked. A source comparison against that web build's PermissionStore, guild
permission masks, and role comparator established the restriction rules above.
READY hydrates timeout expiry; an omitted timeout in `GUILD_MEMBER_UPDATE`
preserves it, while explicit null clears it. No roles or restrictions were
changed live; those cases have deterministic coverage.

A live official-client capture on 7 October 2026 (desktop 0.0.411,
`web.d3978f1210c00a8f.js`) confirmed friend Save and Reset both use
`PATCH /api/v9/users/@me/relationships/{user}` with a string and explicit `null`,
respectively. Both returned empty `204` responses and corresponding
`RELATIONSHIP_UPDATE` events with `type: 1` and the saved string or `null`.
The DM title updated without reloading and the original unset nickname was
restored. The event arrived before the HTTP response for Save and after it for
Reset, so reconciliation must handle either order.

A second pass used the same account in official Discord and SakuraCord. An
official Save updated SakuraCord's existing DM row without a reload; a Reset
saved in SakuraCord produced `RELATIONSHIP_UPDATE` with `nickname: null` in the
independent official session and restored its DM title without a reload. Native
timeline presentation must also be invalidated when relationship nicknames
change, so cached message author labels follow the live value.

## Protobuf preservation

User-settings type 1 and Frecency type 2 are binary protocols. Preserve unknown
fields and untouched siblings when applying an edit. A partial update has different
meaning from a complete replacement. Apply data versions before overwriting newer
local/provider state. Do not replace the whole proto with only a decoded feature.

The relevant feature codec defines whether a request sends a complete updated
proto or only changed fields; this varies between settings. Decode the merged
server response and Gateway settings updates through the same owner. Wire-level
emptiness can require an explicit empty field rather than omission.

## Status and custom status

The provider retains one pending account status pick, its settings data version
and account identity. It overlays received status while pending and survives
connection loss locally until saved, superseded or rejected. READY applies it
before publishing self-member state/presence. READY or RESUMED schedules one
silent save after 5–10 seconds when needed; losing app focus can flush once per
edit until the next connection cycle. Termination itself does not flush.

Status and custom-status writes share a save slot. An edit made during a PATCH
must remain pending after the earlier response. User-initiated saves may retry
one `429` when the server delay is at most 30 seconds; automatic saves do not.
`400 / 50105` reloads settings instead of opening the account safety circuit.
A stale/out-of-date result must not silently replace a newer user pick.

Explicit status and custom status have different expiry support: timed presence
picks are not implemented; custom-status expiry is supported. Custom-status saves
preserve surrounding settings and start relative expiry at submission. A failed
profile-stage status write keeps its draft without replaying prior profile stages.

## Server folders and DM pins

Rail edits PATCH type-1 settings field 14 (`GuildFolders`). Encode one top-level
entry per server or folder, drop emptied folders, and preserve untouched/unknown
bytes and stored servers missing from the current catalogue. Do not rewrite
`guild_positions` as a side effect. Serialize saves and retain the latest desired
layout; definite failure restores the confirmed layout. Merely drawing or expanding
a folder adds no request.

DM pins use flags in the account's `@me` channel notification overrides, preserving
unrelated flags/settings. The app projects pinned ordering without mutating the
provider's channel catalogue or persisting a workspace snapshot. See
[pin contracts](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/DirectMessagePinSettingsTests.swift).

## Emoji, GIFs, stickers and sounds

Favourites and usage history share Frecency type 2 but have different encodings
and presentation order. Do not generalize one feature's ordering to the others.

| Feature | Durable distinction |
| --- | --- |
| Emoji | Ordered favourites in field 5. Message usage is field 6, reaction usage field 13. Both usage maps are saved together, each capped at 100 entries by its latest sample; the merged response and full Gateway echo update every session. |
| GIFs | URL-keyed map with format, source URL, dimensions and monotonic order; presentation is descending order, including extensionless sources. |
| Stickers | Field 3 favourites; clearing requires the explicit empty container. Changed-field patches preserve siblings and consume the merged response. Field 4 usage updates preserve unrelated map entries and unknown bytes. |
| Sounds | Field 8 favourite IDs; stored insertion order differs from picker availability/numeric-ID ordering. Field 11 is played-sound history. |
| Slash commands | Field 7 maps command keys to total uses, up to ten packed recent-use timestamps, frecency and rounded score. A save includes field 7 and any pending emoji usage; it keeps the 500 most recently used entries; the Gateway echoes the full stored proto to every session. |

Usage recording and delayed frecency persistence must not turn every send/play
into an unrelated synchronous settings write. A failed explicit favourite edit
rolls back to provider-authoritative state. Ready/Gateway guild catalogue updates
reconcile the same caches without invented REST fallbacks. Detailed ranking and
codec algorithms belong to the linked implementation and its tests.

The official Fresh desktop client captured on 2026-10-07 (host 0.0.411,
web build 630444, `web.90d3ab34abfe98da.js`) records message emoji only after a
successful send, retaining duplicate occurrences and excluding code. Inserting
or discarding a draft and editing a message do not record uses. Adding a reaction
optimistically records both reaction and message usage; removing it does not
undo either use. Unicode keys retain tone variants; custom keys are snowflakes.
The same build’s command submission source (`545152`, `onMessageSuccess`)
records parsed Unicode/custom emoji from successful command options; this path
is source-corroborated, not part of the live message/reaction capture.

Emoji ranking uses the shared scorer in
[DiscordFrecencyStore](../../App/Sources/SakuraCord/Models/DiscordFrecencyStore.swift),
with distinct message and reaction formulas. Resolve known, role-eligible emoji, take the first
42, then fold tone variants and apply picker availability; do not refill slots
removed at those later stages. Stable ties retain JavaScript object enumeration
order. Empty histories seed Discord's defaults without marking them pending.
Resolve Unicode identities through the key catalogue and actual shortcodes;
search keywords are not identity aliases (for example, `bug` must not resolve
to snail, nor `heart` to love letter). The follow-up live comparison with
`web.b5e982817c690727.js` confirmed the same scoring and persistence modules.
Custom lookup retains the [emoji role restrictions](https://docs.discord.com/developers/resources/emoji#emoji-object).
The official EmojiStore admits unrestricted emoji, or a known member whose roles
intersect the restrictions. It also resolves purchasable subscription emoji in
guilds with `ROLE_SUBSCRIPTIONS_ENABLED`; this is lookup eligibility for locked
previews, not permission to send. Subscription roles require a non-null
`subscription_listing_id` and presence of the `available_for_purchase` tag
(including null). This edge case is source-corroborated and covered by deterministic
tests; the live comparison account had no restricted emoji in its usage history.

The message hover toolbar's quick reactions rank Unicode and custom emoji
together using reaction history, independently of emoji sent in messages.
[QuickReactionPolicy](../../App/Sources/SakuraCord/Models/QuickReactionPolicy.swift)
adds no request beyond the shared settings load. Nitro-locked emoji may appear
in picker previews but are excluded from quick reactions. Resolve and fold as
above, then drop custom emoji that cannot be a new reaction in that channel:
external emoji without Use External Emojis in a server, unavailable
emoji, other-server or DM custom emoji without Nitro, animated emoji without
Nitro, and role-restricted emoji the member lacks. Discord exempts managed emoji
from the Nitro lock; SakuraCord's reaction guard does not, so the toolbar
follows the guard rather than offer an emoji it would reject. If fewer than
three remain, append 💯 😆 💖, fold again and take three. Unicode emoji use the preferred skin tone. A reaction the user
already added changes only the tooltip to “Click to remove”; clicking toggles
it through the ordinary reaction path. Adding a reaction updates local usage;
removing it does not reverse that usage. Other sessions adopt the ranking
through type-2 settings updates, not reaction Gateway events.
The section is hidden with its divider unless reaction creation is allowed: private
channels other than the system DM, or server channels with Add Reactions where
the member is not pending, outside archived threads. Discord also offers them in
archived threads it can reopen because its reaction path unarchives the thread
first; SakuraCord's shared reaction path does not unarchive. A timeline too
narrow for the wider toolbar omits the section.
Source: web build `634304` (`web.843cc7edc28c426c.js`, chunk
`5c04c2e4ef438cd1.js`) on 10 October 2026. The official toolbar also hides quick
reactions while Shift expands it; SakuraCord has no expanded toolbar. Animated
subscription emoji exempt from the Nitro lock are not modelled.

Pending uses persist per account and replay over received histories. A successful
save acknowledges only the submitted prefix, so a use made while the request is
in flight survives exactly once. Defer incoming histories during a save and reject
older data versions. Flush shortly after connection/resume (10 ms plus up to 10 s),
every two hours plus up to ten minutes, on connection close, and alongside any other type-2 settings save. Desktop focus changes are not the mobile inactive trigger.
The provider gathers the account owner’s pending emoji batch immediately before
a type-2 write and acknowledges it from that same request’s merged response;
favourite saves do not require a second usage PATCH.
Partial fields 6/13 preserve unrelated settings and unknown nested fields; never
send an old complete settings blob to update usage.

Local preference export/import is a separate
[architecture boundary](../ARCHITECTURE.md#settings-and-presentation-boundaries);
it never transfers Discord-synchronized settings.
