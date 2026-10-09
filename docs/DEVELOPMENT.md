# Development

Run commands from the repository root. Start with [Setup](#setup) and
[Launch modes](#launch-modes); use [build and verification](#build-and-verification)
for checks, [troubleshooting](#troubleshooting) for failures, and
[report a problem](#report-a-problem) for support. Exact ownership lives in
[Architecture](ARCHITECTURE.md); focused suite selection lives in [Testing](TESTING.md).

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

In the `--offline` demo, **Settings → Updates → Browse Pull Request Builds**
shows the production build browser with sample data. Search,
PR selection, and build history work normally; installation is disabled and
the build catalog is not fetched. Normal launches load the published catalog.

To develop against an unpublished Sparkle fork, set
`SAKURACORD_SPARKLE_PACKAGE_PATH` to a local Swift package named `Sparkle` that
exports the built framework, then use the same guarded build and test scripts.
The default dependency remains pinned to the distributed fork version; never
commit a local-resolution lockfile in place of that pin. See
[PR build publication](RELEASING.md#pull-request-builds) for the
distribution contract and rollout prerequisites.

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
existing SakuraCord session through the configured credential mode. Read-only authenticated verification
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

A `https://sakuracord.app/settings/<page>/<control>` link renders a navigation
card. Page-only links open that settings page. The
[settings catalogue](../App/Sources/SakuraCord/Models/Settings/SettingsCatalog.swift)
and [deep-link mapping](../App/Sources/SakuraCord/Models/Settings/SettingsDeepLinkDestination.swift)
own supported destinations; do not maintain a second exhaustive URL inventory.

Examples include `settings/profiles`, `settings/appearance/messages`,
`settings/features/compaction-quality` and `settings/voice-video/input-device`.
A control path uses its stable control ID without the prefix before its first
dot. Legacy General attachment links resolve to Features. Opening a card reveals
the control using Settings search behaviour; it does not change values, bypass
eligibility or enable a disabled parent policy.

The explicit `settings/diagnostics/send` action is described in
[Report a problem](#report-a-problem). It confirms the source conversation,
checks current permissions and account ownership, and shares the existing export
without changing the draft. A URL cannot supply an arbitrary destination.
The `https://sakuracord.app/update` action and `themes/<token>` links remain
supported. `https://sakuracord.app/report` opens the in-app report flow;
`?type=bug` or `?type=feature` chooses the form.

## Local credential mode

For repeated debug builds that cannot conveniently use Keychain, this machine
can opt into the explicitly insecure local credential store:

```sh
./script/debug_credentials.sh enable
./script/build_and_run.sh run
```

The setting is stored in the current user's global Git configuration, so fresh
clones and worktrees use the same mode. Inspect or disable it with:

```sh
./script/debug_credentials.sh status
./script/debug_credentials.sh disable
```

An explicit `SAKURACORD_INSECURE_DEBUG_CREDENTIALS=0` or `1` overrides the
machine setting for one invocation. Existing checkout-local settings are read
only when no machine preference exists. Release and update-enabled packages
always use Keychain and reject an explicit insecure override.

Both Run and Build & Run verify the packaged credential mode and signature
before launch. A stale bundle with a different credential mode is refused.
When working in an older checkout, use the current checkout's launcher:

```sh
/path/to/current/SakuraCord/script/run.sh --checkout /path/to/older/SakuraCord --build
```

It passes the machine preferences explicitly to the older packager and checks
the resulting app before launching it. Omit `--build` to check and launch an
existing bundle. Direct Finder or `open` launches bypass these checks.

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
| `./script/build_and_run.sh package` | Stage a signed debug app without launching it |
| `./script/build_and_run.sh run-release` | Build, stage, and launch an optimized release app |
| `./script/test.sh protocol` | Run protocol package tests |
| `./script/test.sh media` | Run media package tests |
| `./script/test.sh app` | Run application package tests |
| `./script/test.sh packages` | Run the six library package tests |
| `./script/test.sh all` | Run the configured first-party test matrix |
| `./script/code_quality.sh check` | Run the pinned SwiftFormat and SwiftLint policy |
| `./script/ci.sh` | Run code-quality and release checks, the full first-party test matrix, and the app build |

Hosted CI runs `./script/ci.sh packages` (checks and library tests) and
`./script/ci.sh app` (app tests and build) as parallel jobs, each with its own
compiler output cache. Branch CI runs on pushes to `main`, `nightly`, and
release tags, and on pull requests; a newer push to a pull request cancels its
in-progress run. Release compilation runs alongside any required validation,
and publication waits for both. See
[release validation and caches](RELEASING.md#validation-parallel-packaging-and-caches)
for the exact commit reuse rules and cache boundaries.

Each package's test execution has a three-minute process deadline, separate
from compilation. The test runner streams console output, records Swift Testing
events, and captures process listings and macOS stack samples before terminating
a stalled process group. Diagnostics live in `.codex-runtime/test-diagnostics/`;
failed or cancelled CI runs upload them as a seven-day artifact. A timeout fails
validation without retrying or skipping tests. The CI build-and-test step also
has a 30-minute outer limit covering compilation and framework staging.

### Profiling command pickers

In Instruments, use Time Profiler with the app's `PointsOfInterest` signposts.
`CommandPickerQuery`, `CommandActivation`, `CommandSubmit`, and `PickerViewport`
measure local preparation and native viewport work. `CommandAutocompleteRequest`
measures the autocomplete HTTP request after its typing debounce; it does not
include the later Gateway response. Compare cold catalog loading separately from
warm typing, keyboard navigation, selection, and sending. Viewport timings exclude
Core Animation presentation and must not be reported as complete frame times.

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

The build script saves the selected signing certificate's fingerprint in the
current user's global Git configuration (`sakuracord.codeSignIdentity`). On
first use it prefers the SakuraCord local development identity, then an Apple
Development identity. Subsequent builds require that saved identity. Select a
different identity explicitly for one invocation by its name or SHA-1 hash:

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
code signing, and is not suitable for distributing the app. The setup script
also saves its fingerprint as the machine preference. Local launch commands
refuse missing certificates, ad-hoc signatures, and signatures from a different
identity. Packaging without launch still supports ad-hoc signing, which can be
selected explicitly with `SAKURACORD_CODE_SIGN_IDENTITY=-`.

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

## Troubleshooting

| Symptom | Inspect first | Next step |
| --- | --- | --- |
| Build reports the wrong SDK/compiler or missing Metal tools | `xcodebuild -version`, `swift --version`, selected Xcode | Match the root README requirements and install the Metal component from Setup. |
| Launcher rejects the signing identity | `security find-identity -v -p codesigning` and the saved machine identity | Follow [local signing](#persistent-local-code-signing-identity); do not bypass launch verification. |
| Saved account is missing or credential mode disagrees | `./script/debug_credentials.sh status` | Check [credential mode](#local-credential-mode) before migrating or resetting anything. |
| Another build/test holds the checkout | The operation reported by the guarded script | Let it finish or stop that operation deliberately. Do not delete a live lock or launch a competing build. |
| Computer Use targets another SakuraCord build | `./script/runtime.sh` | Use the complete path printed on its `App:` line; launch through the guarded script. |
| Tests hang | `.codex-runtime/test-diagnostics/` output, events and stack samples | Identify the last started test and blocked owner; do not hide the timeout with retries. |
| Voice, Gateway or history fails | Diagnostics support summary and API/panic logs | Capture the failing phase and timestamp using the recipe below; distinguish permission, transport and decoding failures. |
| Notification sound appears requested but is inaudible | Packaged resource and actual playback event | Follow [native notification audio verification](#verifying-native-notification-audio). |
| Published update/announcement is incomplete | Release workflow checkpoint and validation output | Use [publication recovery](RELEASING.md#publication-and-recovery). |

## Report a problem

Type `/bug` or `/suggest` in a conversation's composer, or use **Help →
Report a Bug…** or **Suggest a Feature…**. SakuraCord files the report with the
signed-in Discord account and fills in the version and system information. Bug
reports can also attach the sanitized Discord API log and the latest panic save
directly. Matching reports appear while you type so you can follow one instead.
Without a signed-in account, the Help menu opens the website form with the same
values prefilled. Reports and discussion follow the shared
[issue-management flow](README.md#issues-and-roadmap).

1. Record the steps, expected result, actual result, and approximate failure time.
   Include whether it occurs in a DM, server, thread, call or offline fixture;
   avoid posting private message content or account identifiers unnecessarily.
2. Open **Settings → Diagnostics**, select **Refresh Status**, then
   **Copy Support Summary** (or **Export Support Summary…**). It includes app,
   system and subsystem information useful for reproducing the problem.
3. For connection or protocol failures, use **Export API Logs…** soon after the
   failure. **Open Diagnostics Folder…** appears when managed logs exist and can
   locate panic snapshots. Clear Logs removes evidence, so export before clearing.
4. Attach the relevant summary/log to the issue or designated support conversation.
   Describe any settings needed to reproduce it and whether another client is
   connected. Review attachments before posting; do not attach credentials,
   Discord storage databases or unsanitized traffic captures.

API log exports and managed disk logs use the shared
[redaction contract](protocol/SESSION.md#diagnostics). That contract also explains
raw in-memory retention, default panic saves and the separate optional capture
modes. A support summary is useful even without enabling additional capture.
Connection diagnostics can help investigate transport stalls, but enable it for
that investigation rather than assuming detailed payload capture includes it.

A `https://sakuracord.app/settings/diagnostics/send` card can offer to share the
same sanitized API export to its source conversation, with a destination-naming
confirmation. Exporting locally does not send anything. Agents follow the
repository's explicit authorization rules before sending files or reproducing
account-mutating actions.

## Temporary PR build verification

Build C verifies returning from a PR track to Nightly after the updater handoff fix.
This test-only branch will be closed without merging.
