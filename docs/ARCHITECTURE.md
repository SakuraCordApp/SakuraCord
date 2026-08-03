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
| `SakuraCordPersistence` | Account-scoped GRDB database, migrations, and user-authored drafts. Discord workspace and history state is never persisted. |
| `MessageRendering` | Parsed message documents, Discord Markdown conversion, and attributed-content planning support. |
| `MediaPipeline` | Media cache interfaces plus voice/video signaling, transport, capture, playback, Opus, H.264, and DAVE integration. |
| `SakuraCordPluginSDK` | Plugin manifest, capability, and permission contracts. |
| `DaveKit` | Swift wrapper over the vendored libdave/MLS implementation used by `MediaPipeline`. |

Dependencies point inward toward models and explicit protocols. Views do not
construct Discord requests or own network transports.

## Application state

`AppModel` is a Main Actor observable projection over a `ChatProvider` and
`SakuraCordDatabase`. It coordinates navigation, session-memory caches, drafts, message
presentation, forum state, interactions, and voice state for the current app
workspace. Views receive narrow values or the model reference.

Launch state is explicit:

- `--offline`, `--offline-long-server-list`, and
  `--offline-forum-performance` construct deterministic fixture providers and
  an in-memory database with Discord networking disabled.
- A normal launch restores a real account session, presents native sign-in, or
  reports a connection failure. It never falls back to mock data. The complete
  chat layout remains a data-free skeleton until the live Gateway bootstrap is
  ready; no account rail, channel, member, read-state, or message presentation
  is restored from disk.

High-frequency presentation state such as remote typing is kept in narrower
observable models so it does not invalidate the complete app tree.

`AppUpdateController` owns Sparkle's `SPUStandardUpdaterController` for the
application lifetime. It starts only when the canonical release bundle contains
the complete production update configuration. Source, debug, ad-hoc developer,
offline, and linked-worktree builds omit that configuration, make no update
request, and leave the native **Check for Updates…** controls disabled.
Production checks the signed feed every six hours while the app is running, or
after launch when a check is overdue, and presents Sparkle's standard update
alert when a release is available. Sparkle persists the user's automatic-check
and automatic-download preferences. Installation remains manual by default.
Sparkle's standard user driver reports no-update and update-cycle failures.

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
- `DiscordAPIDiagnosticStore` receives REST attempts and responses, attachment
  uploads, native-authentication traffic, and main, voice, and remote-auth
  Gateway envelopes at those transport boundaries. It discards user-authored and
  credential-bearing values, IDs, nonces, request IDs, and rate-limit bucket IDs
  before retaining a bounded in-memory session log. The Diagnostics settings
  pane exports the retained JSON Lines data and reports when older entries were
  dropped. Its optional disk capture is off by default and writes private JSON
  Lines session files under Application Support only after the user enables it.

The current production capability gates and request contracts are documented
in [PROTOCOL_BASELINE.md](PROTOCOL_BASELINE.md).

## Authentication and persistence

Native authentication obtains only identifiers issued by Discord's legitimate
flow and presents MFA or user-completed hCaptcha when requested. A newly issued
credential remains memory-only while the main Gateway connects; a valid
`READY.user` supplies its account ID before the credential is stored through
`KeychainCredentialStore`. Failure or cancellation discards the pending value.
An older stored credential that predates installation-identity persistence
performs one unauthenticated Apex installation lookup before Gateway startup;
it does not repeat the fingerprint preflight or force an otherwise valid
credential through the login flow.
Passwords, cookies, captured authorization headers, and analytics identifiers
are not persisted.

An explicitly insecure, debug-only build flag can migrate the credential once
from Keychain into a mode-`0600` file within the app's sandbox Application
Support container. It is excluded from release and update-enabled packages and
is not the production credential contract.

Only user-authored drafts are stored through `SakuraCordPersistence`.
Credentials never enter GRDB, fixtures, logs, or plugin APIs. Discord
workspace, message, read, member, and Gateway state is session-memory only. A
database migration drops the obsolete tables from earlier builds while
preserving drafts. Normal and offline runs use separate storage behavior.

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
resource bundles, copies the complete third-party notices into the app's
otherwise hidden `Contents/Resources/THIRD_PARTY_NOTICES.md`, and ad-hoc signs
the result.

The canonical icon sources are:

- `App/Packaging/SakuraCord.icon`
- `App/Packaging/SakuraCord Flower.icon`

`script/package_dmg.sh` uses the release configuration, verifies the app
signature, builds the DMG, verifies the image, and writes its SHA-256 digest.
Developer ID signing and notarization are not currently part of the release
workflow.

Tag releases enable the canonical Sparkle configuration, generate a signed
`appcast.xml` from the same `SakuraCord.vX.Y.Z.dmg`, and validate the feed signature,
archive signature, bundle metadata, and nested code signatures before staging
both files on a draft GitHub Release and publishing them together. The workflow
refuses to replace assets on an already published tag. Sparkle signing keys
exist only in GitHub repository secrets. The workflow generates the GitHub
release notes once and uses the same complete Markdown body for both the GitHub
Release and the release notes embedded in the signed appcast. If post-publish
automation edits the GitHub Release body, a release-edit workflow downloads the
unchanged DMG, preserves its build number, regenerates and verifies the signed
appcast with the current body, and replaces only the appcast asset. The two
release paths share per-tag concurrency so this refresh cannot race the initial
publication. Maintainers can dispatch the same workflow with a tag to repair an
older feed. The public feed is
`https://github.com/SakuraCordApp/SakuraCord/releases/latest/download/appcast.xml`.
