# Development

This guide collects the day-to-day commands and safety rules that are useful
when working on SakuraCord but too detailed for the public project README.

## Setup

SakuraCord requires macOS 27, Xcode 27 with Swift 6.4, its Metal Toolchain, and Git.
Install the shader compiler if needed with `xcodebuild -downloadComponent MetalToolchain`. After cloning,
complete the required [developer and agent bootstrap](README.md#developer-and-agent-bootstrap)
before committing or pushing.

The application package lives in `App/`. SwiftPM manifests are the build source
of truth, while `SakuraCord.xcworkspace` is a convenience entry point.

## Launch modes

Start with the network-disabled demo unless the work specifically needs a live
session:

```sh
./script/build_and_run.sh --offline
```

To launch the existing `dist/SakuraCord.app` without rebuilding, use
`./script/run.sh`, `./script/run.sh --offline`, or
`./script/run.sh --offline-sign-in`. These are also available as
the Codex environment actions **Run**, **Run Offline**, and **Run Offline Sign In**. These restart the
checkout's app so the selected mode takes effect, and require a previously
built bundle.

Both launch scripts stop and wait for the checkout's app immediately before
launching, including when another launcher reopened it during a build. They
abort if it will not exit and avoid forcing a second instance. Wait for the
script to finish before using Computer Use, which can launch an app on its own.

The focused offline scenes exercise larger or specialized UI states without
contacting Discord:

| Command | Scene |
| --- | --- |
| `./script/build_and_run.sh --offline-sign-in` | Welcome animation and shared native sign-in flow |
| `./script/build_and_run.sh --offline-long-server-list` | Extended server rail |
| `./script/build_and_run.sh --offline-forum-performance` | Large forum |
| `./script/build_and_run.sh --offline-chat-performance` | Large native timeline |
| `./script/build_and_run.sh --offline-pins-performance-autoscroll` | Paginated 5,000-message pins timeline benchmark |
| `./script/build_and_run.sh --offline-incoming-private-call` | Incoming direct-message call |

The offline sign-in fixture uses the production sign-in views and state handling
with an in-memory authentication service. Use any nonempty email and an 8–72
character password; `incorrect` exercises the error state. An email beginning
with `mfa` offers authenticator, backup code, and SMS paths, all using `123456`.
The preview controls simulate QR scanning/approval, expire the code, or replay
the welcome. Successful sign-in opens the ordinary offline workspace. No saved
account is read or changed, and no Discord transport is created. Hosted CAPTCHA
verification requires Discord and is excluded from this offline fixture.
**Build & Run Offline Sign In** rebuilds and launches the same mode from Codex.

Use `./script/build_and_run.sh run` to launch the normal app and restore an
existing SakuraCord session from Keychain. Read-only authenticated verification
may observe existing state and allow normal connection or session-maintenance
traffic, but agent-run verification must not deliberately mutate remote account
state or content without an explicit request for that specific action.

For scoped Inbox verification, debug builds accept
`SAKURACORD_INBOX_VERIFICATION_GUILD_ID`. This limits queued channel
acknowledgements and automatic empty-group dismissal to that guild, including
automatic read acknowledgements during account switching. It does not authorize
manual actions or change which conversations are shown. Leave it unset during
normal use. Use explicit scoped fixtures for mutations and local tests for
bulk actions that would otherwise affect unrelated conversations.

Use `./script/build_and_run.sh run-release` to build the optimized release
configuration, apply the release credential restrictions, and launch the
staged app bundle.

## Settings cards in chat

Paste these HTTPS links into a SakuraCord conversation to render an action card.
Every path below uses `https://sakuracord.app/settings/` as its prefix.

| Destination | Path after the prefix |
| --- | --- |
| Message composer appearance (Default / Legacy) | `appearance/composer` |
| Message appearance (Default / Bubbles) | `appearance/messages` |
| Edit Profile | `profiles` |
| Manage Accounts | `my-account` |
| General | `general` |
| Appearance | `appearance` |
| Theme | `theme` |
| Notifications | `notifications` |
| Voice & Video | `voice-video` |
| Accessibility | `accessibility` |
| Keyboard Shortcuts | `keyboard-shortcuts` |
| Features | `features` |
| Privacy | `privacy-safety` |
| Storage & Downloads | `storage-downloads` |
| Diagnostics | `diagnostics` |
| Updates | `software-updates` |
| Extensions | `extensions` |
| Import & Export | `import-export` |
| About | `about` |
| Export and send sanitised diagnostics | `diagnostics/send` |

Every catalogued setting has a card at `<page>/<control>`, using the page paths
above and the stable control ID without its prefix before the first dot.
For example, `voice-video/input-device`, `general/spell-check`,
`notifications/sound`, `theme/brightness`, `profiles/pronouns`,
`keyboard-shortcuts/toggleMute`, and `import-export/include-theme` target
individual controls. `appearance/composer` and `appearance/messages` retain
their existing paths. The catalog is the source of truth; new controls receive
links automatically.

Features options use `features/<control>`, including `show-hidden-channels`,
`fake-nitro-emojis`, `fake-nitro-stickers`, `fake-nitro-soundboard`,
`fake-nitro-stream-quality`, `compaction-prompt`, `compaction-quality`,
`external-upload-prompt`, and `external-provider`. Older `general/<control>`
attachment links still open their current Features destination. Upload privacy
options use `privacy-safety/remove-media-metadata` and
`privacy-safety/anonymise-file-names`.

Individual cards show the setting's title and use the same reveal and highlight
as Settings search, including fields that load asynchronously. Opening a card
only navigates; actions such as resetting, importing, or changing a profile still
require using the setting itself. Account and Nitro availability still apply.
Attachment options stay visible and are disabled when their parent policy
makes them unavailable; following a link does not enable compression or external uploads.

The diagnostics action asks for confirmation naming the source conversation,
checks message and attachment permissions, and sends the existing sanitised API
log export there without changing the composer draft. Threads, forum posts, and
voice chats keep their own source channel ID even if navigation changes. A
confirmation from a replaced account cannot send. Failed uploads use the normal
outbox retry/discard flow. No destination can be supplied through the URL.

The existing `update` action and `themes/<token>` shared-theme links remain
supported.

## Local credential mode

For repeated ad-hoc debug builds that cannot conveniently use Keychain, a
checkout can opt into the explicitly insecure local credential store:

```sh
./script/debug_credentials.sh enable
./script/build_and_run.sh run
```

The setting is stored only in the checkout's local Git configuration. Inspect
or disable it with:

```sh
./script/debug_credentials.sh status
./script/debug_credentials.sh disable
```

An explicit `SAKURACORD_INSECURE_DEBUG_CREDENTIALS=0` or `1` overrides the
checkout setting for one build. Release and update-enabled packages ignore the
checkout preference and reject an explicit insecure override.

Local credentials are unencrypted files, readable by other processes running
as the same macOS user, under:

```text
~/Library/Containers/dev.sakuracord.SakuraCord/Data/Library/Application Support/SakuraCord/InsecureDebugCredentials/
```

Never enable this mode on a shared or production machine, and never copy its
contents into the repository, logs, or bug reports. With SakuraCord closed,
`./script/debug_credentials.sh delete` disables the mode and removes recognized
local credential files without changing credentials stored in Keychain.

## Build and verification

Use the smallest check that proves the change, then expand validation in
proportion to its risk:

| Command | Purpose |
| --- | --- |
| `./script/build_and_run.sh --verify` | Build, launch offline, and verify the scoped app process |
| `./script/build_and_run.sh package` | Stage an ad-hoc signed debug app without launching it |
| `./script/build_and_run.sh run-release` | Build, stage, and launch an optimized release app |
| `./script/test.sh protocol` | Run protocol package tests |
| `./script/test.sh media` | Run media package tests |
| `./script/test.sh app` | Run application package tests |
| `./script/test.sh all` | Run the configured first-party test matrix |
| `./script/code_quality.sh check` | Run the pinned SwiftFormat and SwiftLint policy |
| `./script/ci.sh` | Run code-quality and release checks, the full first-party test matrix, and the app build |

Hosted CI caches the app and all six library test builds. Release compilation
runs alongside any required validation, and publication waits for both. See
[release validation and caches](RELEASING.md#validation-parallel-packaging-and-caches)
for the exact commit reuse rules and cache boundaries.

Each package's test execution has a three-minute process deadline, separate
from compilation. The test runner streams console output, records Swift Testing
events, and captures process listings and macOS stack samples before terminating
a stalled process group. Diagnostics live in `.codex-runtime/test-diagnostics/`;
failed or cancelled CI runs upload them as a seven-day artifact. A timeout fails
validation without retrying or skipping tests. The CI build-and-test step also
has a 30-minute outer limit covering compilation and framework staging.

### Verifying native notification audio

The packager converts the bundled Discord message clip to AIFF in the main
app's Resources directory. The native notification uses its basename,
`message1`, through `UNNotificationSound`; it does not play a second app sound.

When adding or changing sound resources during development, Notification Center
can retain a failed resource lookup across app rebuilds. After confirming the
packaged file resolves with `Bundle.path(forSoundResource:)`, restarting
Notification Center (`killall NotificationCenter`) clears its in-memory lookup
cache without resetting notification preferences. Use this only for targeted
development verification, not as app runtime behavior or an automatic build step.
On macOS 27, the log `Playing notification sound { nam: ... }` only records the
request; verify the subsequent `Playing sound message1.aiff` event and audible
output before claiming custom playback works.

### Persistent local code-signing identity

The build script uses an installed Apple Development identity, or the SakuraCord
local development identity, automatically so macOS sees rebuilt development
apps as the same signed application. If more than one identity is installed,
select one explicitly by its name or SHA-1 hash:

```sh
SAKURACORD_CODE_SIGN_IDENTITY='Apple Development: Developer Name (TEAMID)' \
  ./script/build_and_run.sh run
```

List the available identities with
`security find-identity -v -p codesigning`. If none are available, either create
an Apple Development certificate from Xcode's Accounts settings or install the
repository's machine-local development identity:

```sh
./script/setup_local_signing_identity.sh
```

The local identity is stored only in the login keychain, is trusted only for
code signing, and is not suitable for distributing the app. The build script
falls back to ad-hoc signing when no identity is installed.

Screen sharing uses ScreenCaptureKit's system content picker. A source selected
there is authorized for that capture session and does not require a separate
global Screen Recording grant. Do not reset TCC or direct users to System
Settings when the picker opens successfully; a permission warning in that case
indicates an incorrect non-picker capture path.

See the [testing guide](TESTING.md) before adding or materially changing
committed tests. Before proposing a broad change, the complete local check is:

```sh
git diff --check
./script/ci.sh
```

Never commit credentials, cookie exports, authorization headers, account
databases, personal Discord data, or unsanitized protocol captures.
