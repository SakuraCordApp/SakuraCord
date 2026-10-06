# Profiles and synchronized settings

[Protocol index](../PROTOCOL_BASELINE.md)

## Owners and checks

| Contract | Source | Representative checks |
| --- | --- | --- |
| Profile reads | [DiscordRESTProviderProfiles.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordRESTProviderProfiles.swift) | [DirectMessageProviderContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/DirectMessageProviderContractTests.swift); [ProviderBootstrapContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/ProviderBootstrapContractTests.swift) |
| Profile saves and widgets | [DiscordRESTProfileSaving.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordRESTProfileSaving.swift); [DiscordProfileWidgetEligibility.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordProfileWidgetEligibility.swift) | [ProfileEditingContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/ProfileEditingContractTests.swift); [ProfileEditorStateTests.swift](../../App/Tests/SakuraCordAppTests/ProfileEditorStateTests.swift) |
| Status | [DiscordProfileSettingsProto.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordProfileSettingsProto.swift); [DiscordRESTProfileCustomStatus.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordRESTProfileCustomStatus.swift) | [StatusPickContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/StatusPickContractTests.swift) |
| Server folders | [DiscordSettingsProtoMerging.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordSettingsProtoMerging.swift) | [GuildFolderSettingsContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/GuildFolderSettingsContractTests.swift) |
| Favourites/frecency | [DiscordSettingsProtoStickers.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordSettingsProtoStickers.swift); [DiscordSettingsProtoSoundboard.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordSettingsProtoSoundboard.swift); [DiscordSettingsProtoCommandFrecency.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordSettingsProtoCommandFrecency.swift) | [ProviderRequestContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/ProviderRequestContractTests.swift); [GIFProviderContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/GIFProviderContractTests.swift); [ApplicationCommandFrecencyCodecTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/ApplicationCommandFrecencyCodecTests.swift) |

## Profile reads

Explicit profile reads use `GET /users/{user}/profile` with `type=popout`,
`with_mutual_guilds=true`, `with_mutual_friends=true`, and
`with_mutual_friends_count=true`; include `guild_id` only in guild context.
SakuraCord requests friend identities because the existing mutual-friends list
uses this same response; a count-only summary cannot populate that list.
Reads coalesce by user and guild context. A successful response's `private`
flag controls the private-profile notice. An unavailable `404` remains a
profile-scoped error rather than implying privacy or stopping the session.

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
| Emoji | Ordered repeated strings in field 5; preserve stored favourite order. |
| GIFs | URL-keyed map with format, source URL, dimensions and monotonic order; presentation is descending order, including extensionless sources. |
| Stickers | Field 3 favourites; clearing requires the explicit empty container. Changed-field patches preserve siblings and consume the merged response. Field 4 usage updates preserve unrelated map entries and unknown bytes. |
| Sounds | Field 8 favourite IDs; stored insertion order differs from picker availability/numeric-ID ordering. Field 11 is played-sound history. |
| Slash commands | Field 7 maps command keys to total uses, up to ten packed recent-use timestamps, frecency and rounded score. A save is a partial proto with only field 7 that keeps the 500 most recently used entries; the Gateway echoes the full stored proto to every session. |

Usage recording and delayed frecency persistence must not turn every send/play
into an unrelated synchronous settings write. A failed explicit favourite edit
rolls back to provider-authoritative state. Ready/Gateway guild catalogue updates
reconcile the same caches without invented REST fallbacks. Detailed ranking and
codec algorithms belong to the linked implementation and its tests.

Local preference export/import is a separate
[architecture boundary](../ARCHITECTURE.md#settings-and-presentation-boundaries);
it never transfers Discord-synchronized settings.
