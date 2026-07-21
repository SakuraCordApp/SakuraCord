# SakuraCord

SakuraCord is a native macOS 27 Discord-client research project written in Swift 6.4 and SwiftUI. It includes a flag-gated, fully offline mock-data mode and an experimental native account provider.

## Important warning

DO NOT USE THIS CLIENT IN ITS CURRENT STATE. SOME ACTIONS, INCLUDING SENDING DMS OR LOADING EMOJIS, MAY GET YOUR ACCOUNT TEMPORARILY DISABLED (THIS HAS HAPPENED TWICE). USE AT YOUR OWN RISK.
SakuraCord is unofficial and is not affiliated with Discord. Discord does not support third-party normal-account clients, and using session credentials outside its supported bot/OAuth APIs may result in account termination.

## What works now

- Native server rail, channel and DM sidebar, message timeline, member inspector, quick switcher, menus, shortcuts, and Settings scene.
- Mock-backed channel history and live provider events.
- Experimental account bootstrap, guild/channel/DM history, text sending, editing, deletion, and reactions through native REST requests.
- Native password, MFA, and user-completed hCaptcha sign-in without an embedded Discord login page.
- Native voice and camera video with device controls, Opus/H.264 media, voice-server migration, and DAVE support.
- Sending, editing, deleting, replying-ready models, reactions, drafts, optimistic outbox state, file staging, drag-and-drop, emoji, and GIF URL attachments.
- Typed Discord snowflakes, provider and Gateway codec boundaries, Keychain credential store, GRDB account database, markdown renderer, media cache interface, and plugin permission SDK.
- Sandboxed app entitlements and a separate plugin-host executable boundary.

## Run

Requirements: macOS 27 and Xcode 27.

```sh
./script/build_and_run.sh
```

The Xcode workspace is `SakuraCord.xcworkspace`.

Use `./script/build_and_run.sh --offline` for fully offline mock-data testing, or `./script/build_and_run.sh --offline-long-server-list` for the extended server-rail fixture. Normal launch never constructs or displays mock data.

Use `--verify`, `--debug`, `--logs`, or `--telemetry` for process verification and development diagnostics.

## Releases

Push a semantic-version tag such as `v0.1.0` to build the release app, package
it as `SakuraCord.dmg`, and publish it on the repository's GitHub Releases page:

```sh
git tag v0.1.0
git push origin v0.1.0
```

The release workflow uses the tag for the app version and the GitHub Actions
run number for the bundle build number. It ad-hoc signs the app but does not
Developer ID sign or notarize it, so Gatekeeper will warn users who download it.

To build the same DMG locally after installing `dmgbuild`:

```sh
python3 -m pip install dmgbuild==1.6.7
./script/package_dmg.sh
```

Codex worktrees automatically receive isolated build, bundle, process, and test
identities. Use the **Run Offline** environment action for concurrent visual
testing; see [Parallel worktree workflow](docs/PARALLEL_WORKTREES.md) for the
agent and merge procedure.

`App/Packaging/SakuraCord.icon` is the default app icon. Self-builds can opt into the bundled flower design with:

```sh
SAKURACORD_APP_ICON="SakuraCord Flower.icon" ./script/build_and_run.sh
```

## Tests

```sh
./script/ci.sh
```

Real credentials, cookie exports, captured authorization headers, account databases, and unsanitized Gateway fixtures must never be committed.
