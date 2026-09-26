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
| `MediaPipeline` | Media cache interfaces, profile image processing, plus voice/video signaling, transport, capture, playback, Opus, H.264, and DAVE integration. |
| `SakuraCordPluginSDK` | Plugin manifest, capability, and permission contracts. |
| `DaveKit` | Swift wrapper over the vendored libdave/MLS implementation used by `MediaPipeline`. |

Dependencies point inward toward models and explicit protocols. Views do not
construct Discord requests or own network transports.

The app resource catalog vendors SocialSymbols' GitHub and Discord symbol sets
for About and Discord’s default Server Guide header artwork. Attribution lives
in `THIRD_PARTY_NOTICES.md`. No SocialSymbols package dependency is used.

## Application state

`AppModel` is a Main Actor observable projection over a `ChatProvider` and
`SakuraCordDatabase`. It coordinates navigation, session-memory caches, drafts, message
presentation, forum state, interactions, and voice state for the current app
workspace. Views receive narrow values or the model reference.

Launch state is explicit:

- `--offline`, `--offline-long-server-list`, and
  `--offline-forum-performance` construct deterministic fixture providers and
  an in-memory database with Discord networking disabled.
- `--offline-sign-in` uses the same offline provider, credential isolation, and
  in-memory database, but waits at the production sign-in view. A transport-free
  authentication fixture supplies password/MFA and QR events; only successful
  completion releases the mock workspace bootstrap.
- `--offline-pins-performance-autoscroll` opens a deterministic 5,000-message
  paginated pin fixture through the production pin state and shared native
  timeline, using the existing display-link scroll benchmark and signposts.
- A normal launch restores a real account session, presents native sign-in, or
  reports a connection failure. It never falls back to mock data. The complete
  chat layout remains a data-free skeleton until the live Gateway bootstrap is
  ready; no account rail, channel, member, read-state, or message presentation
  is restored from disk.

High-frequency presentation state such as remote typing is kept in narrower
observable models so it does not invalidate the complete app tree.
`MessageComposerState` owns channel/thread drafts, reply targets, attachments,
and the outbox. Its account-local slowmode state keeps per-conversation
confirmation deadlines and in-flight send reservations. All message send entry
points check that state before consuming drafts or dispatching; REST and Gateway
confirmations reconcile by message ID. Both composer appearances share the same
countdown and native, non-interactive hover popover. Draft writes capture their account database, are serialized,
and drain during account teardown. Clearing drafts joins the same write queue:
earlier edits are deleted and later edits are preserved, including when clearing
all accounts. Draft restoration also joins this queue before reading stored text
and checks the composer's edit revision at publication, so clearing or editing
invalidates earlier restoration results. Switching, logout, and failed startup share
load cancellation and presentation reset, including pins and composer state.
`AppModel` remains the workspace coordinator; feature state should have an
explicit owner rather than accumulating unrelated fields in extensions.

`GuildOnboardingStore` owns account-scoped question presentation, unfinished
answer drafts, and membership confirmation. `SakuraCordModels` defines the live
configuration, selected IDs, validation rules, and member flags;
`DiscordProtocol` refreshes configuration, submits one answer mutation, and
confirms membership through the existing Gateway member query. The app restores
its own drafts only when join time and confirmed server answers still match,
prunes deleted options, and invalidates in-flight work on account changes.
Onboarding and member screening independently gate message, thread, forum, and
retry paths. Bootstrap carries READY’s self-member records for every guild,
so an unknown membership never implies unfinished onboarding. Confirmed unfinished
memberships cover the guild content inside the existing navigation/window chrome
with `GuildOnboardingView`, reusing the sign-in gradient and native glass controls.
Question transitions animate only when the step changes; cached entries remain
visible across navigation and background refreshes.
Completed memberships navigate to customization or Server Guide through scrolling
channel-list entries with the same native hover and toolbar as channels. Guide
visibility follows Discord’s resource-channel flag or unfinished first-week tasks,
not the guild feature flag alone.
The same account-scoped feature store owns live guide configuration, confirmed
member task progress, and resource history. `DiscordProtocol` owns guide REST
contracts; resource side panels reuse the native timeline renderer with identity chrome
and the composer omitted. Viewing the guide is read-only; visits require successful
history access after an explicit task selection, and send tasks require a confirmed
self-authored message event. Resource previews do not complete visit tasks.
Onboarding dropdowns use the shared `SelectionField` control, including its native
search, tokens, keyboard navigation, and single/multiple selection modes.
Post-join edits are optimistic in the feature store, coalesced for one second,
and serialized per membership. Confirmations update the baseline without
replacing newer edits; failures roll back only the failed version. Optimistic
role previews never grant messaging permissions. Channel edits overlay only
selection bits on the notification store so unrelated settings remain live.
Channel management is a global Settings feature preference, off by default;
when enabled, the channel sidebar consumes authoritative guild/channel opt-in
flags from the existing notification-settings store. Channel permissions remain
independent. Draft writes join the clear/teardown barriers and storage accounting;
server configuration, member records, roles, and channel catalogs are never persisted.
An unfinished draft retains baseline option IDs and its membership join timestamp
solely to detect conflicts against a fresh server read, never to restore confirmed
Discord state.

`AppUpdateController` owns Sparkle's `SPUStandardUpdaterController` for the
application lifetime. It starts only when the canonical release bundle contains
the complete production update configuration. Builds packaged without that
configuration make no update request and leave the native **Check for Updates…**
controls disabled. Code-signing identity does not determine updater eligibility;
official ad-hoc-signed releases include the production update configuration.
Production checks the signed feed every six hours while the app is running, or
after launch when a check is overdue, and presents Sparkle's standard update
alert when a release is available. Sparkle persists the user's automatic-check
and automatic-download preferences. Installation remains manual by default.
Sparkle's standard user driver reports no-update and update-cycle failures.
The Updates settings pane also persists a regular/nightly release-track choice.
Until the user makes that choice, the selected track matches the installed
bundle, so a fresh Nightly installation checks the Nightly feed and a fresh
Regular installation checks the Regular feed.
`AppUpdateController` supplies the selected signed feed through Sparkle's
dynamic-feed delegate. Changing tracks immediately requests a silent Sparkle
information check, or queues one until the current update cycle ends. When that
probe finds an update, the controller asks Sparkle to present its normal update
alert; an up-to-date result remains silent. Returning to the regular track
selects the stable feed immediately. SakuraCord's macOS 27 Sparkle 2.9.6 fork lets an
installed Nightly build explicitly accept the signed Regular build even when
its workflow build number is lower. The normal Sparkle alert, verification,
download, installation, and relaunch flow remain in place; Regular builds keep
upstream downgrade protection enabled.

## Window modal presentation

Custom full-window modals use `WindowModalOverlay`. Feature models and local
bindings own presentation values; `WindowModalCoordinator` owns presentation
order, input ownership and focus restoration for each window. A covered view
cannot receive modal input, and closing transitions retain ownership until
removal. Retained, closed quick-switcher hosts never own input. Native input
surfaces consult the coordinator and clear transient hover state when ownership
changes; SwiftUI window roots use `windowModalInputScope` and hover controls use
`onModalHover`. Event monitors also check their source view's ownership. The
window root keeps hit testing enabled: disabling it on `NavigationSplitView`
changes sidebar toolbar insets. The native modal host blocks background pointer
input without changing workspace layout.

`windowModal` adds the shared panel surface and sizing/dismissal environment.
The media viewer uses the same host with its own visual transition and removal
delay. Forum composition and blocking incoming calls use that host too. Native
sheets and anchored popovers retain their platform presentation; covered anchor
popovers close, while a popover belonging to the active modal owns Escape first.

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
  lifetime, but production gives them separate provider-owned `URLSession`
  connection pools. A confirmed REST transport timeout can therefore replace
  only the stalled pool without interrupting Gateway heartbeats. Safe reads may
  retry once on the replacement; mutations are never replayed after an
  ambiguous failure. A session-wide safety stop still cancels both without
  affecting unrelated app networking.
- Connection diagnostics are a separate, default-off app preference. When
  enabled, a per-task REST delegate adds allowlisted URLSession metrics to the
  existing bounded API log: task timing offsets (including incomplete phases),
  HTTP protocol, connection reuse, network flags, byte counts, and local pool
  generation/task numbers. Pool replacements are logged too. Metrics never
  retain request/response objects, addresses, ports, credentials, or content;
  payload capture and panic save do not implicitly enable this option. Turning
  it off also suppresses late metrics from in-flight tasks. It adds no requests
  and does not change timeout, retry, or connection-pool behavior.
- Every authenticated REST route uses the central transport. Views and feature
  helpers do not create one-off authenticated `URLSession` paths.
- Production Gateway ETF is parsed directly from the decompressed bounded byte
  buffer into a JSON-compatible value tree. Dispatch DTOs decode directly from
  that tree, avoiding a second JSON serialization/parser pass while retaining
  the same typed validation and event ordering. Dispatch files are grouped by
  bootstrap, guild, channel, thread, message, member, interaction, and voice
  responsibility. Search, history, profiles, emoji, presence, channel, member,
  and bootstrap provider methods likewise have separate files.
- Gateway-to-provider and provider-to-app event queues each hold at most 500
  deliveries. The synchronous projection of each READY, READY_SUPPLEMENTAL, or
  GUILD_CREATE payload uses one delivery slot, with its events still consumed
  individually in order. Adjacent channel snapshots for the same guild collapse
  only when their differences are limited to names and topics; cooldown, access,
  membership, ordering, and other state changes remain delivery barriers.
  Ordinary channel updates convert only the changed channel, while category changes rebuild the
  dependent channel metadata. Unchanged channel projections are not republished.
  Initial voice state arrives as one batch, preserving every participant without
  consuming a queue entry per user. Overflow discards pending incomplete work,
  publishes a terminal session-invalidated event, records the failed delivery
  boundary in diagnostics, and stops the session. The app clears its incomplete
  projection and offers saved-account reconnection without draining stale UI
  work first. It never continues presenting a silently truncated event stream.
  Queue continuations resume only after releasing the queue mutex, preventing
  lock inversion with task cancellation during account teardown.
- Provider message reconciliation keeps at most 10,000 messages, evicting the
  oldest insertion. This working set is independent of visible conversation
  caches. Reactions on evicted messages reload the target through the existing
  anchored-history route before deciding the mutation. Typing resolves authors
  through user indexes instead of scanning message history. Sparse Gateway
  edits still reach retained UI and forum projections after cache eviction;
  in-flight history refreshes merge those edits before publishing their result.
  Current-user identity events likewise reconcile retained authors and mentions
  independently of the provider working set, including forum previews and pages
  that are still being prepared before publication. Refresh journals preserve
  event order: later message identity fields supersede earlier global identity
  changes, while later identity events update already-journaled message fields.
- `CatboxAttachmentUploader` is a separate unauthenticated app service used
  after a host choice in the oversized-attachment warning or the user’s saved
  Automatically policy and selected host. It never
  receives Discord credentials or sends a Discord message; its validated HTTPS
  result is inserted into the originating draft.
- `DiscordAPIDiagnosticStore` receives REST attempts and responses, attachment
  uploads, native-authentication traffic, and main, voice, and remote-auth
  Gateway envelopes at those transport boundaries. Detailed capture retains
  ordinary REST request/response bytes and already-parsed Gateway values in a
  session memory ring bounded by entry count and estimated retained size,
  initially accounting for original payloads. A shared encoding boundary
  discards user-authored and credential-bearing values, IDs, nonces, request
  IDs, and rate-limit bucket IDs before any export or disk write. It caches
  the sanitized JSON line and releases both the raw source and the sanitized
  value tree on first successful output. Retention accounting preserves the
  conservative sanitized payload estimate. Cache size changes and eviction are
  reconciled under the store lock before output returns; continuous capture
  accounts for the sanitized cache before
  retaining each entry. An output keeps its captured history even if caching
  evicts entries from memory. Eviction and Clear Logs also release retained
  sources. Payload sanitization, including authentication HTTP traffic, Gateway
  identify/resume and session/voice setup, and remote-auth and voice sockets,
  waits for manual export or panic save. Continuous disk capture sanitizes each
  write. WebSocket JSON parsing and operation-name extraction also wait for
  output; raw payloads count toward the same memory budget before sanitization.
  The export also retains
  scalar-only Voice socket closure, reconnect, timeout, migration, and
  app-state lifecycle events even when detailed payload capture is disabled,
  so transport loops remain diagnosable without retaining content. The
  first JSON Lines header in manual exports, disk sessions, and panic saves
  includes the app-owned support summary and its snapshot time. Startup installs
  the fixed non-identifying schema before disk capture begins; session startup
  and Diagnostics refresh its health snapshot. Mode flags and the retained count
  are filled from the log store at output time. Existing disk headers describe
  capture start, and panic size limits include the variable-sized header. The
  Diagnostics settings pane exports the retained JSON Lines data and reports
  when older entries were dropped. Its optional disk capture is off by default
  and writes private JSON Lines session files under Application Support only
  after the user enables it. Each capture stops at 64 MiB, the directory
  retains at most four managed session files (256 MiB total), and Clear Logs
  removes both the memory ring and saved session files while resuming a fresh
  bounded file when capture remains enabled.

  Default-on panic save retains detailed payloads for sanitized output in that
  bounded memory ring, even when explicit detailed capture is off. Every HTTP
  error response, non-cancellation HTTP or WebSocket failure (including TLS and
  timeouts), failed socket/voice lifecycle event, missed heartbeat ACK, and
  abnormal Gateway closure saves a snapshot. Content-loading owners also report
  failures after checking account and presentation ownership, covering decoding,
  message/history, search, profile, picker, member, media, and voice failures
  above the network boundary. Normal cancellation and intentional socket shutdown
  do not trigger saves. Failure entries retain the error type, allowlisted system
  error domain, and numeric code; descriptions, userInfo, and arbitrary domains
  are discarded because they can contain private URLs or content.
  Related reports coalesce into one save attempt: the same error propagated
  through transport and content-loading owners, a failed HTTP response and its
  derived error, and a socket connection's failure/closure sequence. Weak object
  identities avoid retaining errors or response metadata; independent errors with
  equal codes and new socket connections remain eligible. Coalesced reports still
  enter the memory ring and optional continuous log. Clear Logs resets this
  tracking; duplicate reports do not retry a failed disk write.
  Panic save keeps the latest three private snapshots in the same directory. The
  newest is `SakuraCord Discord API Panic Save.jsonl`; `-2` and `-3` filename
  suffixes mark its predecessors. Each snapshot includes the triggering event
  and newest complete entries within the 64 MiB disk limit (192 MiB total),
  independently of continuous capture. A new snapshot finishes writing before
  atomic renames rotate the older files. Clear Logs also removes all three
  snapshots. Disabling panic save prevents future automatic writes and
  restores lightweight capture unless explicit detailed capture remains
  enabled.

The current production capability gates and request contracts are documented
in [PROTOCOL_BASELINE.md](PROTOCOL_BASELINE.md).

## Authentication and persistence

Native authentication obtains only identifiers issued by Discord's legitimate
flow and presents MFA or user-completed hCaptcha when requested. A newly issued
credential remains memory-only while the main Gateway connects; a valid
`READY.user` supplies its account ID before the credential is stored through
`KeychainCredentialStore`. Failure or cancellation discards the pending value.
An approved QR credential or an older stored credential that predates
installation-identity persistence performs a bounded, best-effort unauthenticated
lookup before Gateway startup: one Apex request, followed by one `/experiments`
fallback only when Apex fails or omits the identity. Discord may omit the
optional identity from both successful responses; SakuraCord then starts
Gateway without it. The lookup runs once per provider and does not replay the
authentication exchange or force an otherwise valid credential through login.
Passwords, cookies, captured authorization headers, and analytics identifiers
are not persisted.

The login page can import a selected saved account from the stable Discord
desktop client on this Mac. App owns automatic discovery, the bounded read-only
Chromium local-storage reader, the integrated login step, and Electron session
decryption. A read-only sandbox exception is scoped to the standard stable
Discord local-storage database directories, including the two installed folder
casings. When macOS app-data privacy denies a read, a native access panel opens
at the discovered folder; a read-only security-scoped bookmark remembers the
grant for subsequent imports. The grant is balanced around each scan, and
cancelling discovery also dismisses any access panel. Session decryption still
requires macOS Keychain authorization.
The reader follows the current LevelDB manifest,
sequence numbers, and tombstones; it never scans abandoned files for credentials
or modifies Discord's storage. Only numeric account entries from the current
`tokens` map are eligible, excluding the analytics entry. Source usernames are
presentation hints, and avatars use the existing image pipeline. Accounts already
saved in SakuraCord are excluded before selection. The import step shares the
login card's transitions, loading surfaces, and Back/Escape navigation; leaving
discovery cancels its task and restores QR sign-in. The selected session remains memory-only until the existing
pending-provider flow receives `READY.user`, verifies that it matches the selected
account ID, and stores it under that ID. Imported secrets, source
storage, and Discord's Safe Storage key are never exported or logged.

Multiple account credentials may coexist as separate Keychain items. The app
keeps only the saved account's display name, username, avatar URL, last-used
date, and preferred account identifier in user defaults so the account picker
can identify sessions without reading every secret or issuing profile probes.
Switching accounts disconnects and drains the current account-scoped work,
then bootstraps the selected existing credential through the same provider
path used for launch restore. It does not replay the login exchange. Logging
out from account management removes the selected account's Keychain item,
picker metadata, and derived search/catalog disk caches; logging out the active
account first disconnects its live session and drains pending cache writes.
Credential and picker removal precede disposable cache deletion; a cache-cleanup
failure is reported without retaining the saved credential.
Removing a stale saved account also removes its metadata and derived caches
when its Keychain credential is already absent.

An explicitly insecure, debug-only build flag can migrate the credential once
from Keychain into a mode-`0600` file within the app's sandbox Application
Support container. It is excluded from release and update-enabled packages and
is not the production credential contract.

Only user-authored message and unfinished onboarding drafts are stored through `SakuraCordPersistence`.
Credentials never enter GRDB, fixtures, logs, or plugin APIs. Discord
authoritative workspace, message, read, member, and Gateway state is
session-memory only. A database migration drops the obsolete tables from earlier
builds while preserving drafts. Normal and offline runs use separate storage
behavior.

The provider deliberately persists disposable derived metadata under
`Caches/dev.sakuracord.SakuraCord`, scoped by account ID:

| Directory | Content and retention |
| --- | --- |
| `ForwardSearchPeople` | Up to 10,000 learned user identities and 20,000 guild nickname associations, retained until cleared or logout. |
| `QuickSwitcherChannelStore` | Up to 50,000 channel IDs preserving equal-score search order across launches, retained until cleared or logout. |
| `EmojiCache` | Per-guild emoji catalogs, fresh for seven days; stale catalogs can be used if refresh fails. Retained until cleared or logout. |

These files do not contain message bodies or credentials and never restore the
workspace before live bootstrap. **Privacy & Safety → Clear Local Activity**
removes the active account's derived files and learned historical associations,
as well as local destination/emoji usage history. Pending writes are drained
before deletion. Emoji requests started before clearing cannot reinstall their
results in the provider's catalog cache or on disk. The app's session-only emoji
catalog remains available for display, including results of already-requested
loads; clearing local activity does not invalidate that presentation data.
Its renderer lookup stores compact emoji asset identities and resolves their
image URLs on use, preserving explicit asset overrides and the existing shared
media-cache keys.
Live Discord identities and memberships remain available;
only identities learned again after clearing become eligible for history
persistence. Saved channel insertion order is discarded and rebuilt by subsequent
channel discovery; the app clears its copy of that order and invalidates its
search index at the same time. These metadata files have their
own retention policy and are outside the draft/media storage budget below.
The user-configured local storage limit is shared by persistent drafts and the
disposable media cache: draft content reserves its measured space first, and
the media cache applies the remainder as its LRU limit. Drafts are never
evicted automatically.

External-link confirmation is an app-wide preference. Its default mode asks
before opening domains outside an app-wide, user-managed list of normalized
exact hostnames; trusting a hostname does not implicitly trust its subdomains.
The user may instead require confirmation for every external link or suppress
confirmation for all otherwise valid external links. Unsupported URL schemes
remain blocked independently of this preference. The trusted-domain list is
resettable but excluded from preference exports.

Startup and account switching publish READY-derived read state in one atomic
Main Actor update after building it off-main. Once the initial channel is known,
the app starts its read-only newest-history request concurrently with the
remaining navigation projection and consumes that single in-flight task when
the channel loader starts. This prefetch is process-only coordination: it is
cancelled on account/session reset and never persists messages across launches.
The current user's full profile is likewise prefetched into the account-scoped
in-memory profile cache once the initial guild context is known, and again when
that context changes, so the You Bar can present its final profile card without
an intermediate loading-sized popover. Prefetch failures remain silent and the
ordinary on-demand profile loader remains the fallback.

Authenticated performance launch modes retain detailed signposts and exact
resource windows for startup, account switching, DM/server/channel navigation,
older-history pagination, timeline/member scrolling, parsing, state commits,
and rendering. They use real credentials and network data while suppressing
acknowledgements and other account mutations; offline fixtures are not accepted
as production performance evidence.

## Settings transfer

The app-owned `SettingsTransferService` exports selected local preference categories
into versioned JSON `.sakurasettings` documents. The typed preference registry
allowlists transferable values; imports merge supported entries independently,
validate types and choices, preserve omitted or unsupported values, and report
when a newer app is needed. Runtime changes go through the existing settings
owners. Launch at login and Sparkle preferences use their platform owners;
download-folder bookmarks are restored only when the destination is accessible
on the current Mac. Credentials, Discord-synchronized settings, account data,
messages, and operating-system permission grants are never transferred.

The packager registers `dev.sakuracord.settings`, compiles the document icon
asset catalog alongside the app icon, and lets macOS compose the folded-page
icon with a pink-to-white background, the full flower badge, and the short
“Settings” label. The background source is
`App/Packaging/SettingsDocumentBackground.svg`; the badge uses the transparent
Liquid Glass flower variants in `Brand/Logos/SakuraCord-Flower/transparent`,
filling the available center-image canvas with the complete flower.

## Account settings

`AccountDetails` and `AccountDevice` are private, session-only domain values;
email and phone are never added to public `User` or persisted `SavedAccount`.
The production provider retains READY account fields, merges sparse own-user
updates, and owns the on-demand account/device reads and current-session hash.
`AccountSettingsState` owns Settings loading, errors and device results, checks
account-session ownership before publishing, and is recreated when the active
account changes. The devices destination shares its parent's fetched list.
The native form masks contact fields until explicitly revealed and provides
read-only device information. Disconnect clears the provider's private data.
`CurrentMacHardware` reads the local `hw.model` identifier once through Darwin's
`sysctlbyname` and resolves it through `MacHardwareModels.json` in
`Resources/MacHardwareIcons`. The catalog maps 59 model identifiers to 19 distinct
bundled PNGs; models with identical supplied images share one resource. Only the
current-session row uses this local icon; other sessions retain their reported
OS icon. Unknown model identifiers
use the generic icon. The retained PNGs are bundled unchanged,
and no local hardware identifier is sent to Discord or persisted with accounts.

## Profile editing and rendering

`SakuraCordModels` owns profile snapshots, scoped editable values, draft changes,
collectibles, name styles and widgets. Editable fields preserve missing, null
and explicit values; draft changes separately represent unchanged, clear and
set. `ProfileDraftProjection` resolves main and server inheritance into the same
`UserProfile` used by member popovers, without erasing the raw values needed for
later saves and resets.

The Settings-owned `ProfileEditorState` manages scope selection, local changes,
validation feedback and temporary preview files. It retains the originating
account session and invalidates obsolete loads with a revision and draft
generation. Unsaved edits block scope changes and Settings dismissal until
saved or reset. The account-bar preload prepares a main-profile editing baseline in the account model,
so a newly created Settings editor can initialize its fields synchronously. Selected
avatar/banner artwork, cosmetics and derived avatar colours warm separately in the existing
bounded media caches; artwork never blocks baseline adoption. The expanded preview
measures both columns in its layout pass rather than resizing after a height
preference arrives. The editor also adopts the provider's cached editable response;
a server response also supplies its main-profile baseline. It joins an existing
preload instead of issuing a competing request. Reentering Profiles reuses clean
snapshots for one minute, then refreshes while preserving unsaved changes and
explicit recovery state. An unloaded scope keeps the previous canvas visible
under a translucent authentication-loading animation, with editing blocked until
the new baseline arrives. Cache resolution does not display that animation. A failed scope change retains the previous scope. Returning
to the app or receiving a profile invalidation marks retained editor data stale;
the visible clean editor refreshes immediately while keeping its preview mounted.
Unsaved drafts defer that refresh until reset or saved. User and member Gateway
updates invalidate full profile caches, including reads already in flight.
`ProfilesSettingsPage` feeds draft projections into
`MemberProfilePopover`; display-name fonts and effects, avatar decorations,
nameplates, profile effects and frames, membership sections and widget cards
share their production renderers. Editor actions are supplied through the
environment. Cosmetic and image pickers use `StableAnchoredPopoverPresenter`,
the same semitransient host as the theme/gradient picker, including actions from
the profile preview. These pickers use fixed compact sizes during loading and
browsing. Cosmetic grids apply selections directly to the local draft, with Nitro
items grouped below other owned items. Their clipping and selection outlines share
one corner radius resolved from the stationary popover surface, so scrolling does
not change individual options' rounding.
Name style and widget-removal dialogs use the shared `WindowModalOverlay`.
Add Widget, game search, and game tags use compact anchored popovers, sharing the scope
picker’s rounded hover and selection rows. Game search uses the status editor’s
plain input treatment; game widgets do not show suggestion carousels. The editor's
upper section shares `ProfileExpandedSurface` and `ProfileWidgetBoardViewport`
with the expanded profile modal: one themed surface, a fixed profile column,
divider, and independently scrolling widget board. The editor retains inline
fields, widget management, and anchored pickers within that presentation. Its height
fits the taller content column up to the modal height, avoiding empty space below
short profiles.
The page retains the Settings background, navigation title, and outer scrolling.
Status bubbles share their production renderer; the editor's button supplies
hover expansion and holds the bubble expanded while its status popover is open.
Confirmed own-account custom status updates are authoritative over member-list
presence data, including explicit clears. Successful editor saves update the app
model immediately; external updates refresh the saved baseline without replacing
an unsaved status draft.
Eight equally sized customization tiles reflow from four
columns to two. The scope picker is a native trailing toolbar button showing
the main-profile symbol or selected server icon. Scope and server-tag
selectors use native popovers; selectable popover rows derive their highlight
shape from the system container. Name and pronoun fields overlay their rendered
text without adding layout padding; editable text keeps its hover outline while
editing. Cosmetic removal is the first ordinary tile in its option grid, with
the same bounds and selection treatment as other items. Bio editing keeps the shared native rich-text
view and emoji attachments in place, preserving inherited values until an edit.
The emoji picker returns to that text view's selection through its own window;
normal typing leaves selection with the native editor. Add Widget offers personal
and game-list widgets without the Game Stats catalogue or account-linking flow.
Existing application widgets retain their configured `mini_profile` surface,
full statistics, identity and connection resources, and board management.

Expanded profiles pass their existing card bounds to the modal host through
`ProfileFrameAnchorKey`. The host draws rear and front frame artwork outside its
rounded clip, preserving the profile's layout, theme, corners and scrolling.
Editor previews use the same frame renderer; native popovers and inspectors
omit frames until their hosts can accommodate artwork outside the card.

`ProfileThemeState` resolves explicit theme colours or an avatar-derived palette
for the shared card and colour controls. `MediaPipeline`
extracts that palette using the reference median-cut algorithm and Chromium's
opaque WebP chroma interpolation. Derived colours remain presentation data;
editing one endpoint saves the other displayed endpoint explicitly. Server
theme reset clears both overrides together. The profile retains the user's
default avatar asset separately so removing an avatar can preview that result.

`DiscordRESTProvider` owns editable snapshots, catalogues, avatar history,
entitlement checks, widget resources and all authenticated profile requests.
Identity, profile metadata and server-tag writes execute in order; widget
writes form an independent save group. Each confirmed stage is removed from
the draft even if a later stage fails. Ambiguous transport failures require an
authoritative reload before another explicit save; confirmed stages are never
replayed. Credential rotation from a confirmed main identity response completes
before the following stage. Profile presentation generations prevent older
reads from replacing newer REST or Gateway state. Saved identity and scoped
profile events update retained popovers, members and message projections.

Custom status is edited locally in a compact anchored popover with an integrated
text row, circular emoji action, and expiry menu. It shares the profile draft's
Save Changes, Reset, and unsaved-change protection; its emoji picker opens a nested
popover. The editor submits status through the existing settings-protobuf update
after other profile stages succeed, retaining a failed status draft without
repeating acknowledged profile writes. Relative expiry starts at submission.
Its provider retains
the surrounding status settings, preserves unrelated fields, reconciles the
response and schedules expiry. Personal and game widget editing requires both
full Nitro and the matching early-access assignment, with the same checks at
presentation and provider boundaries. Activity and Wishlist are outside the
profile presentation and editor.

`MediaPipeline` owns profile crop geometry and static/animated image processing.
File-import actions read fresh bytes under their security-scoped access;
immutable remote images and generated preview files use the shared media loader.
Profile GIF selection uses Discord's provider-specific image proxy, while its
selection notification proceeds independently. Avatar and banner changes stay
local until profile save. Widget images use the provider's upload allocation and
signed upload URL before their returned reference enters the local widget draft.
Crop work is cancellable, and the owning editor removes its temporary previews
when they are reset or released.

## Message and media flow

History responses and Gateway events decode into the same domain message
model. Updates merge only fields present in the event. `MessageRendering`
parses message content; it does not own a competing message-row view.

Pinned-message pages and mutation serialization belong to account-scoped
`AppModel` session state. Typed page and message-pin values live in
`SakuraCordModels`; `ChatProvider` owns the paginated read and Pin/Unpin
boundary; `DiscordRESTProvider` and `MockChatProvider` implement it. The pins
popover supplies `.pins(channelID)` rows to `NativeMessageTimelineView`, so it
reuses normal rich rendering, menus, accessibility, and exact-message
navigation without inheriting history acknowledgement, unread, composer, or
sidebar ownership.

Inbox follows the same ownership split. `InboxState` holds account-scoped
Mentions pages, frozen Unread groups, prepared rows, mutation tasks, and the
`MessageRowsUpdateJournal`. `ChatProvider` owns mention pagination/dismissal,
Inbox protobuf settings, and scheduled-event reads and actions. Channel and
thread acknowledgements remain in `AccountReadStateModel`; scheduled-event
read states have their own typed provider cache. The `.inbox(tab)` conversation
reuses the native timeline and pinned/search message navigation, with only
visible group, forum-post, and event controls hosted in AppKit. Loading or
scrolling this surface never inherits timeline visibility acknowledgements.
Account changes cancel work and discard retained Inbox content.

Every rendered conversation surface—guild text and announcement channels,
direct and group direct messages, voice-channel chat, regular threads, and
forum-post conversations—configures the same virtualized
`NativeMessageTimelineView` and Core Graphics row painter. Surface-specific
headers, pagination, permissions, composers, and thread/forum state remain
outside that shared row engine. SwiftUI/AppKit hosting inside the timeline is
bounded to interaction surfaces that need native controls, including editing,
media playback, menus, pickers, and component interactions.

The channel member inspector likewise uses one virtualized AppKit/Core Text
canvas. Its bounded visible-row overlays remain mounted and animated during
live scrolling so avatars, decorations, presence, and activity emoji preserve
their normal presentation. As rows enter and leave the viewport, their hosting
views are recycled rather than allocated and destroyed. Cached canvas frames
remain underneath as a zero-gap presentation while optional new animated-frame
expansion is deferred until motion ends. The animation decode scheduler tracks
timeline and member-list gestures independently, so one surface ending a
gesture cannot reopen the decode lane while another is still moving. Canvas
image requests use presentation-sized pixel budgets (96-pixel
avatars/decorations, 64-pixel emoji, and 32-pixel guild badges), while full-row
nameplates retain their 512-pixel budget. Animation frames use lossless raster
compression when it saves space, expanding pixels only while Core Graphics
reads them. Large animations submit the current frame to the compositor and
release previous uploads; frame timing and shared playback clocks remain with
the presentation owner. In-memory cache budgets still account for the full
decoded raster size.

Emoji, sticker, and soundboard pickers share `NativePickerDocument`: an AppKit
scroll document with exact row origins and binary viewport lookup, following
the timeline's bounded presentation model. Only visible rows and one adjacent
row on either side retain native views or SwiftUI hosts, recycled as they leave
the viewport. Large scrollbar jumps do not
instantiate intervening cells or depend on lazy height estimates. The existing
sticker and soundboard cell views retain their controls. Emoji rows use native
buttons, cached Core Text glyphs matching the existing emoji preview metrics, and
the shared decoded-image loader and animation canvas. Selection, menus, media
playback, accessibility, and activation policy remain with the cell owner;
picker models retain catalog filtering, search, and account actions.
Catalog updates preserve the visible row and its offset when that row survives.
`PickerSectionRail` owns shared sidebar chrome, guild icons, and ordering/filter
helpers; unknown catalogs remain reachable for loading and retry.

The app's shared animation loader also stores prepared public-media frames in
`MediaPipeline`'s existing bounded disk cache. Versioned keys include the source
content hash and pixel budget; mapped files retain compressed frame bytes
without copying them into the heap. These disposable representations share
the media quota, eviction, and Clear Cache lifecycle with encoded assets.
Checksummed metadata preserves frame timing, pixels, and color spaces. A
missing, invalid, or unsupported representation uses the normal source decoder.
This cache contains media representations, never workspace or message-history
snapshots.

Display-name fonts use the shared persistent media cache. The app decodes font
assets off the main actor and retains immutable Core Text descriptors and sized
fonts for native text preparation and drawing. Font availability refreshes the
affected timeline identities and member-list text without replacing either
canvas with per-name hosting views. Timeline and member-list names retain their
existing role-color and interaction policy; profile identities use the shared
multiline name renderer with the user's colors and effects.

`MediaPipeline` owns public-media caching and the complete native voice/video
stack. `DaveKit` is an implementation dependency of `MediaPipeline`; the app
target does not import it directly.

Attachment compression also belongs to `MediaPipeline`. ImageIO and AVFoundation
produce smaller image/video copies using the selected quality preset. Still images
use JPEG automatically, or PNG when transparency must be preserved. General settings
expose Ask/Automatically/Never policies and compression quality; the quality control
is hidden when compression is disabled, and the file host is shown for automatic
external uploads.
Unsupported file types continue to the external-upload policy. The app owns
account-limit checks, the compaction/external-upload prompt queue, temporary-file
lifetimes, and persisted attachment policies in General settings. Files
whose privacy-prepared upload size fits the account limit skip compaction,
including Photos imports. Compacted outputs use the same prepared-size check.
A compacted copy is attached only if it fits; otherwise the original proceeds
to the external-upload policy. Neither step sends the draft.

Upload metadata removal also belongs to `MediaPipeline`, independently of
compaction. The app's Privacy setting is enabled by default and supplies one
preparation closure to Discord and external upload providers. Providers reserve
and send the prepared copy, then discard it on success, failure or cancellation;
source files are never edited. Images retain pixels, colour and orientation;
video uses passthrough movie export, preserving alternate-track groups, languages
and playback defaults while omitting identifying and timed metadata. Unsupported
container layouts require original-file consent. Attachment selection checks metadata removal and warns if it fails. Users can
cancel or explicitly attach the original; approval is bound to its SHA-256 digest
and cleared on account reset. Uploads use a stable copy of the approved bytes.
A changed file requires new confirmation. Documents and archives are outside this
media-only setting. See the protocol baseline for supported formats and evidence.

Profile image processing also belongs to `MediaPipeline`. Animated WebP export
uses the pinned libwebp SwiftPM dependency because the current macOS ImageIO
destination API can decode WebP but cannot write it. This is a codec capability
gap; the app continues to target macOS 27. The codec receives image bytes and
pixel transforms and has no Discord credentials or networking responsibilities.

## Plugins

`SakuraCordPluginSDK` defines future-facing capability and permission
contracts. `SakuraCordPluginHost` is a separate executable and signing target,
but it is intentionally inert and currently loads no plugins. No plugin
receives a Discord credential or credential handle.

The sandboxed runtime, installation workflow, and extension points are roadmap
work, not an implemented architecture claim.

## Packaging

`script/build_and_run.sh` builds the debug or release SwiftPM product, assembles the `.app`,
compiles the selected Icon Composer source with `actool`, embeds frameworks and
resource bundles, copies the complete third-party notices into the app's
resources, copies the canonical versioned release notes into
`Contents/Resources/Releases`, and ad-hoc signs the result.

The canonical icon sources are:

- `App/Packaging/SakuraCord.icon`
- `App/Packaging/SakuraCord Flower.icon`

`script/package_dmg.sh` uses the release configuration, verifies the app
signature, builds the DMG, verifies the image, and writes its SHA-256 digest.
Developer ID signing and notarization are not currently part of the release
workflow.

Stable and `vX.Y.Z-Beta-N` tag releases enable the canonical Sparkle
configuration, generate a signed `appcast.xml` from the same tag-specific DMG,
and validate the feed signature,
archive signature, bundle metadata, and nested code signatures before staging
both files on a draft GitHub Release and publishing them together. The workflow
refuses to replace assets on an already published tag. Sparkle signing keys
exist only in GitHub repository secrets. Each tag must contain a reviewed
`Releases/<tag>.json` with the complete GitHub and Discord copy. CI validates
that versioned file but never generates or rewrites its authored notes or
announcement description. The workflow uses the same complete Markdown body
for the GitHub Release and signed appcast, derives the Discord embed title from
the tag, posts the pre-made embed description with a generated role mention
and release button, and stores public copy/delivery checkpoint assets for
idempotent repair runs.
The source branches maintain `main` as an ancestor of `nightly`. A dedicated
main-push workflow fast-forwards nightly when it has no independent commits.
When the branches have diverged, it creates a normal merge, runs the complete
CI suite against that merged tree, and pushes only after validation. Conflicts
or rejected non-fast-forward pushes stop without rewriting either branch.
Workflow-authenticated pushes do not recursively trigger another CI run; an
exact fast-forward is already covered by the triggering main run, while a new
merge commit is explicitly validated before publication. Release validation
also requires every stable or beta tag commit to be reachable from nightly.
Nightly beta tags must point to commits on the `nightly` source branch, use
human-facing `vX.Y.Z Beta N` release and Discord titles, and use tag-specific
`SakuraCord-vX.Y.Z-Beta-N.dmg` assets. They use the same validation, packaging, and
publication jobs, publish as GitHub prereleases, and select their dedicated
Discord channel and role. The application reads the latest signed prerelease
appcast through the website's Cloudflare Worker at
`https://sakuracord.app/updates/appcast.xml`. The Worker selects the newest
published GitHub prerelease and serves its canonical `appcast.xml` asset with a
short cache lifetime; no generated source branch or cross-repository write
credential is required.
If a maintainer edits the GitHub Release body after publication, a
release-edit workflow downloads the unchanged DMG,
preserves its build number, regenerates and verifies the signed appcast with the
current body, and replaces only the appcast asset. The two release paths share
global release concurrency so this refresh cannot race the initial
publication. Maintainers can dispatch the same workflow with a tag to repair an
older feed. The public feed is
`https://github.com/SakuraCordApp/SakuraCord/releases/latest/download/appcast.xml`.
