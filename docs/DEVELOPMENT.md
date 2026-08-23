# Development

This guide collects the day-to-day commands and safety rules that are useful
when working on SakuraCord but too detailed for the public project README.

## Setup

SakuraCord requires macOS 27, Xcode 27 with Swift 6.4, and Git. After cloning,
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

The focused offline scenes exercise larger or specialized UI states without
contacting Discord:

| Command | Scene |
| --- | --- |
| `./script/build_and_run.sh --offline-long-server-list` | Extended server rail |
| `./script/build_and_run.sh --offline-forum-performance` | Large forum |
| `./script/build_and_run.sh --offline-chat-performance` | Large native timeline |
| `./script/build_and_run.sh --offline-incoming-private-call` | Incoming direct-message call |

Use `./script/build_and_run.sh run` to launch the normal app and restore an
existing SakuraCord session from Keychain. Read-only authenticated verification
may observe existing state and allow normal connection or session-maintenance
traffic, but agent-run verification must not deliberately mutate remote account
state or content without an explicit request for that specific action.

Use `./script/build_and_run.sh run-release` to build the optimized release
configuration, apply the release credential restrictions, and launch the
staged app bundle.

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
| `./script/test.sh app` | Run application package tests |
| `./script/test.sh all` | Run the configured first-party test matrix |
| `./script/code_quality.sh check` | Run the pinned SwiftFormat and SwiftLint policy |
| `./script/ci.sh` | Run the local CI entry point |

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
./script/code_quality.sh check
./script/test.sh all
./script/ci.sh
```

Never commit credentials, cookie exports, authorization headers, account
databases, personal Discord data, or unsanitized protocol captures.
