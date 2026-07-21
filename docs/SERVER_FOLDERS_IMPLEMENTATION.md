# Server folders implementation record

Research and implementation date: 19 July 2026. The comparison used public source code and a static inspection of Discord's public, signed-out web assets. No account token, cookie, authorization header, personal settings payload, or live authenticated request was captured or replayed.

## Sources and pinned revisions

- Discord public [Gateway events](https://docs.discord.com/developers/events/gateway-events) and [rate limits](https://docs.discord.com/developers/topics/rate-limits). The public Ready schema does not document normal-account `user_settings_proto` or server folders.
- Discord's public app bootstrap, web build `580156`, version hash `af6069991f1b0f884f278271a1fe36a2432d056c`, released 17 July 2026 and inspected 19 July 2026. Its public JavaScript decodes `user_settings_proto` on Ready, handles `USER_SETTINGS_PROTO_UPDATE`, and defines preloaded-settings field 14 as `guild_folders`.
- [Paicord revision `694761c1938b73bb60bd58942674dfe73aab1135`](https://github.com/llsc12/Paicord/commit/694761c1938b73bb60bd58942674dfe73aab1135), authored 14 July 2026. Relevant paths are `Stores/SettingsStore.swift`, `Common/Guilds/GuildScrollBar.swift`, `Common/Guilds/GuildButton.swift`, and the generated preloaded-user-settings protobuf.
- [Swiftcord v1 revision `14465d927ebe1ba34b3befa00f9365fad7b56eb9`](https://github.com/SwiftcordApp/Swiftcord/commit/14465d927ebe1ba34b3befa00f9365fad7b56eb9), authored 29 May 2024. Relevant paths are `Views/ContentView.swift` and `Views/Server/ServerFolder.swift`; its Gateway model came from the pinned DiscordKit dependency.

## Comparison and chosen behavior

| Area | Current Discord public client | Paicord | Swiftcord v1 | SakuraCord |
| --- | --- | --- | --- | --- |
| Initial folder data | Gateway Ready `user_settings_proto` | Same | Gateway-backed `guildFolders` | Same; no folder-specific REST bootstrap request |
| Live changes | `USER_SETTINGS_PROTO_UPDATE` | Same | No separately reviewed update path | Same, accepting preloaded settings type `1` |
| Proto shape | field 14 `guild_folders`; folder fields 1 IDs, 2 ID, 3 name, 4 color | Same generated schema | Dependency model exposes equivalent folder values | Manually decodes the same fields and ignores unknown fields |
| Unlisted guilds | Outside folders, before stored folder sequence | Sorted newest-first using `joined_at` | Same | Before folders, descending snowflake as the bootstrap-safe time proxy |
| Anonymous folder entry | Standalone guild | Standalone guild | Standalone guild | Standalone guild |
| Expand state | Local presentation state | Local `UserDefaults` per folder ID | Local `UserDefaults` | Local `UserDefaults` key `GuildFolders.<id>.isExpanded` |
| Collapsed folder | First four guilds in a 2x2 preview | Same, static icons | Same basic preview | Same, static icons; full animation resumes when expanded |

SakuraCord retains its existing Gateway Identify and capability baseline. Folder decoding does not change Identify, subscriptions, authentication, retry policy, or account actions. Unknown, malformed, non-preloaded, or folder-free settings payloads fail back to the existing flat guild rail. Duplicate guild IDs are emitted once; duplicate folder IDs degrade to standalone guild items so SwiftUI never receives duplicate identities.

## Request and action budget

| Scenario | Folder-specific REST requests | Gateway actions |
| --- | --- | --- |
| Cold bootstrap | 0 | Uses the existing Ready dispatch |
| Warm bootstrap | 0 | Uses the existing Ready dispatch |
| Discord folder update | 0 | Consumes one server-issued update dispatch |
| Expand or collapse | 0 | 0; local state only |
| Malformed or absent settings | 0 | 0 retries or probes |

The ordinary cold REST bootstrap remains three sequential reads: current user, guilds, and private channels. Tests fail if the removed `/users/@me/settings-proto/1` read returns.

## Testing and rollback

Deterministic tests cover the exact protobuf wrapper fields, folder ordering and metadata, unlisted-guild fallback, Ready/update DTOs, long-list offline folders, and the zero-extra-request bootstrap contract. App tests cover WebP frame-delay selection. No automated test makes a Discord request.

The feature is rollbackable by reverting the `GuildFolder`/`GuildRailItem` snapshot fields, settings dispatch handling, and folder view together. The only persisted value is local expansion state; leaving those harmless keys behind does not alter Discord state or network behavior.
