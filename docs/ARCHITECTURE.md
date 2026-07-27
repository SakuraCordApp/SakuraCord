# SakuraCord architecture

SakuraCord is a SwiftPM-backed macOS application collected in
`SakuraCord.xcworkspace`. SwiftPM remains the build source of truth; the
workspace is a convenience entry point.

## Package ownership

| Package | Responsibility |
| --- | --- |
| `App` | SwiftUI application, AppKit bridges, app state, authentication UI, settings, and the plugin-host executable. |
| `SakuraCordModels` | Stable domain values, typed snowflakes, messages, commands, interactions, and provider events. |
| `DiscordProtocol` | Provider contract, REST and Gateway implementation, Discord DTO decoding, credentials, request scheduling, and offline provider. |
| `SakuraCordPersistence` | Account-scoped GRDB database, migrations, drafts, messages, and non-credential cache state. |
| `MessageRendering` | Parsed message documents, Discord Markdown conversion, and attributed-content planning support. |
| `MediaPipeline` | Media cache interfaces plus voice/video signaling, transport, capture, playback, Opus, H.264, and DAVE integration. |
| `SakuraCordPluginSDK` | Plugin manifest, capability, and permission contracts. |
| `DaveKit` | Swift wrapper over the vendored libdave/MLS implementation used by `MediaPipeline`. |

Dependencies point inward toward models and explicit protocols. Views do not
construct Discord requests or own network transports.

## Application state

`AppModel` is a Main Actor observable projection over a `ChatProvider` and
`SakuraCordDatabase`. It coordinates navigation, caches, drafts, message
presentation, forum state, interactions, and voice state for the current app
workspace. Views receive narrow values or the model reference.

Launch state is explicit:

- `--offline`, `--offline-long-server-list`, and
  `--offline-forum-performance` construct deterministic fixture providers and
  an in-memory database with Discord networking disabled.
- A normal launch restores a real account session, presents native sign-in, or
  reports a connection failure. It never falls back to mock data.

High-frequency presentation state such as remote typing is kept in narrower
observable models so it does not invalidate the complete app tree.

## Discord boundary

`ChatProvider` is the application-facing boundary. `MockChatProvider` provides
deterministic fixtures, while `DiscordRESTProvider` owns authenticated
production behavior.

Within the production provider:

- `GatewaySession` alone owns the Gateway socket, compression stream, heartbeat
  and ACK tracking, resume state, reconnect policy, and connection generation.
- `DiscordRESTProvider` owns authenticated request preparation, rate-limit
  scheduling, caches, capability gates, upload coordination, safety stops, and
  domain-event decoding.
- REST and Gateway share one `DiscordClientMetadata` source and one provider
  lifetime. A session-wide safety stop cancels both without affecting unrelated
  app networking.
- Every authenticated REST route uses the central transport. Views and feature
  helpers do not create one-off authenticated `URLSession` paths.

The current production capability gates and request contracts are documented
in [PROTOCOL_BASELINE.md](PROTOCOL_BASELINE.md).

## Authentication and persistence

Native authentication obtains only identifiers issued by Discord's legitimate
flow, presents MFA or user-completed hCaptcha when requested, validates the
current user, and stores the resulting credential through
`KeychainCredentialStore`. Passwords, cookies, captured authorization headers,
and analytics identifiers are not persisted.

Account data is stored through `SakuraCordPersistence`. Credentials never enter
GRDB, fixtures, logs, or plugin APIs. Normal and offline runs use separate
storage behavior.

## Message and media flow

History responses and Gateway events decode into the same domain message
model. Updates merge only fields present in the event. `MessageRendering`
parses message content; it does not own a competing message-row view.

Every rendered conversation surface—guild text and announcement channels,
direct and group direct messages, voice-channel chat, regular threads, and
forum-post conversations—configures the same virtualized
`NativeMessageTimelineView` and Core Graphics row painter. Surface-specific
headers, pagination, permissions, composers, and thread/forum state remain
outside that shared row engine. SwiftUI/AppKit hosting inside the timeline is
bounded to interaction surfaces that need native controls, including editing,
media playback, menus, pickers, and component interactions.

`MediaPipeline` owns public-media caching and the complete native voice/video
stack. `DaveKit` is an implementation dependency of `MediaPipeline`; the app
target does not import it directly.

## Plugins

`SakuraCordPluginSDK` defines future-facing capability and permission
contracts. `SakuraCordPluginHost` is a separate executable and signing target,
but it is intentionally inert and currently loads no plugins. No plugin
receives a Discord credential or credential handle.

The sandboxed runtime, installation workflow, and extension points are roadmap
work, not an implemented architecture claim.

## Packaging

`script/build_and_run.sh` builds the SwiftPM product, assembles the `.app`,
compiles the selected Icon Composer source with `actool`, embeds frameworks and
resource bundles, and ad-hoc signs the result.

The canonical icon sources are:

- `App/Packaging/SakuraCord.icon`
- `App/Packaging/SakuraCord Flower.icon`

`script/package_dmg.sh` uses the release configuration, verifies the app
signature, builds the DMG, verifies the image, and writes its SHA-256 digest.
Developer ID signing and notarization are not currently part of the release
workflow.
