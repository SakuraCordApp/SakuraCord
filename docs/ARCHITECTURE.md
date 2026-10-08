# Architecture

SakuraCord is a native macOS app built with SwiftPM. The package manifests are
the build source of truth; `SakuraCord.xcworkspace` is a convenience entry point.
For commands, use [Development](DEVELOPMENT.md). For wire behaviour, use the
[protocol baseline](PROTOCOL_BASELINE.md).

## Package ownership

| Package | Owns |
| --- | --- |
| [App](../App/Package.swift) | SwiftUI scenes, AppKit presentation, account/workspace coordination, settings, authentication UI, plugin-host executable. |
| [SakuraCordModels](../Packages/SakuraCordModels/Package.swift) | Domain values, typed IDs, messages, commands, interactions, provider events. |
| [DiscordProtocol](../Packages/DiscordProtocol/Package.swift) | Provider boundary, REST/Gateway, DTOs, scheduling, credentials, offline fixtures. |
| [SakuraCordPersistence](../Packages/SakuraCordPersistence/Package.swift) | Account-scoped GRDB storage and migrations for user-authored drafts and created invite links. |
| [MessageRendering](../Packages/MessageRendering/Package.swift) | Message parsing, Discord Markdown, attributed-content planning. |
| [MediaPipeline](../Packages/MediaPipeline/Package.swift) | Media caching/processing; voice/video capture, playback, signaling, transport and codecs. |
| [DaveKit](../Packages/DaveKit/README.md) | Vendored DAVE/MLS encryption bridge, used through MediaPipeline. |
| [SakuraCordPluginSDK](../Packages/SakuraCordPluginSDK/Package.swift) | Plugin manifest, capability and permission contracts. |

Views consume domain state and invoke owners. They do not construct Discord
requests, open authenticated transports, or import DaveKit directly.

## Find the owner

Start at these files and follow their neighbouring extensions. This is an entry
map, not a second inventory of every implementation file. Representative tests
are mapped in [Testing](TESTING.md#choose-the-verification-boundary).

| Work | App model / state | Provider or service | Presentation |
| --- | --- | --- | --- |
| Send, retry, drafts | [MessageComposerState.swift](../App/Sources/SakuraCord/Models/MessageComposerState.swift); [AppModelOutgoing.swift](../App/Sources/SakuraCord/Models/AppModelOutgoing.swift) | [DiscordRESTProvider.swift](../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordRESTProvider.swift) | [ComposerView.swift](../App/Sources/SakuraCord/Views/ComposerView.swift) |
| History and rendering | [AppModelHistory.swift](../App/Sources/SakuraCord/Models/AppModelHistory.swift) | [History provider](../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordRESTProviderMessageHistory.swift); [MessageRendering](../Packages/MessageRendering/Sources) | [NativeMessageTimelineView.swift](../App/Sources/SakuraCord/Views/NativeMessageTimelineView.swift) |
| Inbox and read state | [InboxState.swift](../App/Sources/SakuraCord/Models/InboxState.swift); [AccountReadStateModel.swift](../App/Sources/SakuraCord/Models/AccountReadStateModel.swift) | [DiscordRESTInbox.swift](../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordRESTInbox.swift) | [InboxPopoverView.swift](../App/Sources/SakuraCord/Views/InboxPopoverView.swift) |
| Friends and relationships | [FriendsState.swift](../App/Sources/SakuraCord/Models/FriendsState.swift); [AppModelFriends.swift](../App/Sources/SakuraCord/Models/AppModelFriends.swift) | [DiscordRESTRelationships.swift](../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordRESTRelationships.swift) | [FriendsView.swift](../App/Sources/SakuraCord/Views/FriendsView.swift) |
| Joining, onboarding, Guide | [AppModelOnboarding.swift](../App/Sources/SakuraCord/Models/AppModelOnboarding.swift); [AppModelGuildGuide.swift](../App/Sources/SakuraCord/Models/AppModelGuildGuide.swift) | [DiscordRESTOnboarding.swift](../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordRESTOnboarding.swift); [DiscordRESTGuildGuide.swift](../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordRESTGuildGuide.swift) | [GuildCustomizationView.swift](../App/Sources/SakuraCord/Views/GuildCustomizationView.swift) |
| Profiles and account settings | [ProfileEditorState.swift](../App/Sources/SakuraCord/Models/Settings/ProfileEditorState.swift) | [DiscordRESTProfileSaving.swift](../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordRESTProfileSaving.swift) | [ProfilesSettingsPage.swift](../App/Sources/SakuraCord/Views/Settings/ProfilesSettingsPage.swift) |
| Attachment preparation | [AppModelComposerAttachments.swift](../App/Sources/SakuraCord/Models/AppModelComposerAttachments.swift) | [MediaPipeline](../Packages/MediaPipeline/Sources) | [AttachmentSettingsSection.swift](../App/Sources/SakuraCord/Views/Settings/AttachmentSettingsSection.swift) |
| Bug reports and suggestions | [IssueReportStore.swift](../App/Sources/SakuraCord/Models/IssueReportStore.swift); [AppModelIssueReports.swift](../App/Sources/SakuraCord/Models/AppModelIssueReports.swift) | [IssueReportHubClient.swift](../App/Sources/SakuraCord/Services/IssueReportHubClient.swift) (sakuracord.app); [report-service sign-in](protocol/SESSION.md#report-service-sign-in) | [IssueReportView.swift](../App/Sources/SakuraCord/Views/IssueReport/IssueReportView.swift) |
| Voice and screen sharing | [AppModelVoice.swift](../App/Sources/SakuraCord/Models/AppModelVoice.swift); [AppModelScreenSharing.swift](../App/Sources/SakuraCord/Models/AppModelScreenSharing.swift) | [DiscordVoiceSession.swift](../Packages/MediaPipeline/Sources/MediaPipeline/DiscordVoiceSession.swift) | [ScreenShareWindowOverlay.swift](../App/Sources/SakuraCord/Views/ScreenShareWindowOverlay.swift) |

## Runtime and account lifetime

[AppModel](../App/Sources/SakuraCord/Models/AppModel.swift) is a Main Actor observable
projection over `ChatProvider` and the account database. Feature stores own
local loading, selection, optimistic edits and errors; AppModel coordinates
navigation and account lifetime. High-frequency state such as typing belongs
in narrow observables rather than invalidating the entire workspace.

A normal launch restores credentials or presents sign-in. It never falls back
to mock data. Live workspace state comes from Gateway bootstrap, with a data-free
skeleton until that state is ready. Offline modes select fixture providers and
an in-memory database explicitly; their launch recipes live in Development.

Closing the workspace window with Command-W or the close button keeps the app
and account session running. Reopening the app restores its single workspace.
Command-Q and the Quit menu item terminate the app through the existing active-work
confirmation policy.

Account/session identity guards asynchronous publication. Switching accounts,
logout and failed startup cancel old work and clear its presentation. Draft
writes capture their original database and drain on teardown; clearing and
restoring drafts use the same serialized queue. A restoration also checks the
composer's edit revision so it cannot overwrite a newer edit or clear.

`GuildOnboardingStore` owns in-memory choices, membership confirmation, Guide
configuration and progress. `InboxState` owns frozen Inbox groups and loading;
`AccountReadStateModel` owns channel/thread acknowledgement reconciliation.
Feature stores must not become independent sources of Discord authority.

### On-device translation

`TranslationState`, owned by `AppModel`, holds translation preferences, in-memory
message results (at most 200), and the two composer toggle states. Translation is
off by default. Neither launch, enabling it, nor reading Apple's supported-language
catalog translates text or requests model downloads. An explicit message or draft
action submits work; there is no Discord send/edit operation in the translation
service. A translated draft becomes ordinary editable composer text and follows
the existing draft persistence and send validation paths.

`AppleTranslationCoordinator` admits at most eight queued/active operations.
`TranslationTaskHost` lives at the main window root. Each operation has a distinct
SwiftUI identity and configuration, so identical language pairs still execute.
An explicitly Sendable, nonisolated SwiftUI callback consumes each view-provided
session through an ephemeral session client on the generic executor; they never live in the coordinator or a singleton. Only
Sendable result values cross back to the Main Actor. Cancellation, host removal,
and account teardown remove and resume continuations exactly once. Request IDs,
account sessions, settings snapshots, message content, composer destinations, and
monotonic draft revisions prevent stale completions from publishing or clearing
newer work. Settings changes discard toggle state without changing composer text.

Language identifiers come from `LanguageAvailability` with the same `highFidelity`
preference as the translation configuration. Apple's framework selects its
traditional on-device fallback when the preferred model is unavailable; Apple
Intelligence is not an eligibility gate. Matching retains language and script,
with region fallback only within that script. System Language resolves the ordered
preferred-language list; an unavailable saved target remains saved and produces an
actionable error. Supported and installed are distinct. Translation uses automatic
source detection and lets the SwiftUI session present Apple's source-selection or
model-download consent UI. No preparation call, dummy text, bulk model download,
or fixed HTTP-style timeout is used.

`TranslationTokenProtector` builds a structural plan: mentions, custom and Unicode emoji,
FakeNitro links, timestamps, command mentions, URLs/link destinations, code,
Markdown delimiters, private-use characters, and line breaks remain literal.
Only prose slots reach the model, submitted together through Apple’s same-language
batch API so short fragments share one language-detection and consent flow.
Every slot must return exactly once and cannot
introduce protected syntax; otherwise the complete operation fails closed. There
are no model-visible placeholders to collide with user input, lose, or duplicate.
Splitting prose around syntax intentionally reduces sentence context and can
reduce fluency; a markup-heavy or ambiguous short slot may require a retry/source
choice or fail. Link destinations are conservatively preserved through the final
closing parenthesis on their line. Spoiler prose stays inside its original
boundaries. Both messages and drafts use the same validation.

Translated messages stay separate from `Message.content`. The native timeline
reuses rich-text rendering, selection/copy, link and mention activation, and
spoiler reveal state in a distinct translation region. Caption actions and Copy
Translation are available to accessibility. Presentation updates relayout affected
rows and invalidate retained conversation layouts when necessary. Edits/deletion,
settings and locale changes, eviction, and account teardown invalidate results.
Drafts retain their original plus any edits to the translated version; closing the
strip preserves current text. Sending, navigation, thread closure, IME composition,
and account teardown cancel the affected pending draft operation.

[Apple documents](https://developer.apple.com/documentation/translation/translationsession)
that translation content is processed on-device and its framework usage/performance
metrics exclude source and translated content. This feature does not log or persist
translation results. Model downloads and Apple's diagnostics are separate from
translation processing; Discord networking and ordinary accepted draft persistence
remain unchanged. There is no external translation provider, credential, or fallback.

## Data and event flow

```text
Views → AppModel / feature state → ChatProvider → DiscordRESTProvider
                         ↑                         ↑ REST / Gateway
                    domain events ← ordered provider projection
                         ↓
                prepared native presentation
```

`GatewaySession` alone owns the main socket, compression, heartbeat, resume and
reconnect generation. The provider owns authenticated REST scheduling, DTOs,
capability gates and reconciliation. REST and Gateway share client metadata but
use separate provider-owned URLSession pools: a stalled REST pool can be replaced
without interrupting heartbeats. A session safety stop cancels both.

Gateway-to-provider and provider-to-app queues are bounded. Bootstrap events
are batched without changing event order. Overflow invalidates the session and
clears the incomplete app projection; it never silently drops state and keeps
running. Continuations resume outside the queue lock. Message working sets and
visible conversation caches have different lifetimes: eviction from the provider
must not prevent sparse edits or identity changes reaching retained UI state.

Media preparation and timeline layout happen away from the main-thread commit
where possible. Views reuse prepared content and shared caches. A feature must
not start network work merely because a row redraws.

## Persistence and privacy

| Data | Owner and lifetime |
| --- | --- |
| Account credentials | `KeychainCredentialStore`; new credentials are saved only after authoritative `READY.user` validation. Debug-only local credential mode is described in [Development](DEVELOPMENT.md#local-credential-mode). |
| Saved-account labels, avatar and preferred account | Local picker metadata in user defaults; not an authenticated workspace snapshot. |
| Message drafts and explicitly created invite links | Account-scoped GRDB. Expired links are pruned and checked before reuse; neither restores permissions or membership. |
| Workspace, message history, members, read state, onboarding choices | Session memory; restored from the live provider, not disk. |
| Unsaved emoji/reaction usage | Account-scoped user defaults until acknowledged by Discord; replayed over remote history and removed with the account. |
| Unsaved account status pick | Account-scoped user defaults until saved, superseded or rejected; removed with the account. See [settings synchronization](protocol/SETTINGS.md#status-and-custom-status). |
| Derived people search, channel ordering and emoji catalogues | Account-scoped disposable caches under `Caches/dev.sakuracord.SakuraCord`. Never bootstrap the workspace or store credentials/message bodies. |
| Media cache | Disposable LRU; shares the configured storage budget with drafts, which reserve space first and are never automatically evicted. |
| Report drafts and report-service session | Session memory; drafts are discarded once filed, and both are cleared when the account changes. Attachments use the existing upload-privacy preparation and are read when attached. |
| Diagnostics | Bounded memory and optional/specific disk output. See the single [retention and redaction contract](protocol/SESSION.md#diagnostics). |

Clear Local Activity drains pending writes before removing derived caches and
learning history. Existing live identities remain available; clearing history
must not clear current membership. Logout removes credentials and account
metadata before disposable cache cleanup, so a cleanup failure cannot retain a
saved credential. Account-specific pending settings work is also removed.

Explicit Discord account import reads the stable client's current LevelDB state
and uses macOS-authorized decryption. It neither modifies Discord storage nor
recovers deleted records from abandoned files. Selected credentials remain
pending until `READY.user` matches the chosen account. Passwords, source storage,
Safe Storage keys and imported secrets never enter diagnostics, GRDB or plugins.

## Settings and presentation boundaries

The settings catalogue owns searchable controls and deep-link identities.
[SettingsTransferService](../App/Sources/SakuraCord/Services/Settings/SettingsTransferService.swift)
exports only allowlisted local preferences to versioned
`.sakurasettings` files. Imports validate each entry, preserve omitted/unsupported
values and apply changes through existing owners. Credentials, account content,
Discord-synchronized values, trusted domains and OS permission grants are excluded.
External-link confirmation defaults to a bundled, worldwide list in
`App/Sources/SakuraCord/Resources/trusted-domains.json`. Bundled entries are exact
hostnames: no blanket subdomain trust. File-sharing, raw-content and arbitrary
page-publishing hosts (including Dropbox, Google Sites and Discord attachment
CDNs) require confirmation by default. Ordinary GitHub pages remain trusted;
known GitHub raw, archive, release-download and attachment URLs carry a warning.
Trust never suppresses suspicious-link warnings in Untrusted Domains mode.
Known services may still contain user content or redirect elsewhere; inclusion
is not a guarantee of page safety or a download/content scanner.

Users may add `*.example.com` rules matching one or more subdomain levels,
but not the apex. Matching respects label boundaries. The bundled Public Suffix
List (ICANN and private sections) rejects wildcards over registries and shared
hosting namespaces; without that resource, wildcard validation fails closed.

The preference store seeds each installation once, merging defaults with any
existing list, including an explicitly empty legacy list. Later launches and
catalogue changes preserve edits and removals. A privacy reset restores the
current bundled list; its separate migration marker is not reset or exported.
No catalogue downloads or account requests are needed. Exact entries retain
their existing semantics, and the link-warning checkbox trusts only its exact
hostname. Always Ask and Never Ask retain their existing behaviour.

Platform-owned preferences use their platform services. Download bookmarks are
usable only when accessible on the receiving Mac.

Interface size is an app-wide factor owned by
[InterfaceScale](../App/Sources/SakuraCord/Support/InterfaceScale.swift), because
macOS text styles ignore Dynamic Type. New fonts use `Font.interface`,
`.interfaceSystem` or the `NSFont.interface…` constructors with base sizes;
layout lengths use `InterfaceScale.metric`. Scale each value once: sizes derived
from a scaled frame or font stay unscaled. Content roots (split-view columns,
settings pages, popovers and modals) apply `interfaceScaleRoot()`; never wrap a
view that declares a toolbar, because toolbar items then lose their native
sizing. AppKit-drawn surfaces relayout through their
presentation revisions. At 100% every helper returns its input. Message density
stays in points and is independent. System chrome (window controls, toolbar
items, menus, alerts) keeps the system size.

`WindowModalCoordinator` owns input order and focus for each window;
`WindowModalOverlay` supplies the shared custom modal host. Closing transitions
retain input ownership until removal. Native sheets and anchored popovers keep
their platform behaviour; event monitors must respect modal ownership.
Threads, channel previews and Guide resources reuse the supplementary conversation
pane and native timeline rather than creating another workspace shell.

Profile drafts belong to the editor; permissions, entitlement checks and
confirmed values belong to the provider. MediaPipeline owns crop/encoding work.
Attachment prompts and temporary-file lifetime belong to App; media sanitization
and compaction belong to MediaPipeline. See [messaging](protocol/MESSAGING.md#attachments)
for the upload boundary and [settings](protocol/SETTINGS.md) for profile contracts.

## Plugins, packaging and updates

The SDK exposes future-facing contracts. The separately signed
`SakuraCordPluginHost` executable is currently inert and loads no plugins.
It receives no Discord credential or credential handle.

`script/build_and_run.sh` assembles and signs the bundle, embeds resources and
frameworks, and copies release notes and third-party notices. Guarded launch
checks the chosen credential mode and signing identity. Icon sources and exports
are documented in [Brand](../Brand/README.md); notices remain in
[Third-party notices](THIRD_PARTY_NOTICES.md).

`AppUpdateController` owns Sparkle for the app lifetime. Only bundles with the
complete production update configuration enable it. The selected Regular/Nightly
track supplies the signed feed; the installed track is the default until the
user chooses. Changing tracks checks silently and presents the normal Sparkle
alert when an update exists. Installation is manual by default.

The [release runbook](RELEASING.md) owns branch promotion, tag/copy validation,
signing, feed publication, recovery and the Nightly-to-Regular downgrade opt-in.
Do not duplicate those procedures here.
