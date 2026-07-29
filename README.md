<div align="center">
  <img src="Brand/Icons/Apple-App-Icon/SakuraCord-Apple-App-Icon-256.png" width="168" height="168" alt="SakuraCord app icon">

  <h1>SakuraCord</h1>

  <p><strong>Discord, at home on the Mac.</strong></p>
  <p>A fast, native Discord client shaped around SwiftUI, macOS, and the way desktop chat should feel.</p>

  <p>
    <a href="https://github.com/SakuraCordApp/SakuraCord/releases/latest">
      <img width="137" height="28" alt="Latest release" src="https://img.shields.io/github/v/release/SakuraCordApp/SakuraCord?display_name=tag&sort=semver&style=flat&label=Release&labelColor=555&color=D9578B">
    </a>
    <a href="https://discord.gg/hWNwFXkUTP">
      <img width="195" height="28" alt="Discord community" src="https://img.shields.io/badge/Discord-community-5865F2?style=flat&logo=discord&logoColor=white">
    </a>
    <a href="https://roadmap.sakuracord.app">
      <img width="167" height="28" alt="Public roadmap" src="https://img.shields.io/badge/Public-roadmap-D9578B?style=flat&logo=target&logoColor=white">
    </a>
  </p>

  <p>
    <a href="https://github.com/SakuraCordApp/SakuraCord/actions/workflows/ci.yml">
      <img alt="Build status" src="https://img.shields.io/github/actions/workflow/status/SakuraCordApp/SakuraCord/ci.yml?branch=main&style=flat&label=Build">
    </a>
    <img alt="macOS 27" src="https://img.shields.io/badge/macOS-27-000000?style=flat&logo=apple&logoColor=white">
    <img alt="Swift 6.4" src="https://img.shields.io/badge/Swift-6.4-F05138?style=flat&logo=swift&logoColor=white">
  </p>

  <p>
    <a href="https://github.com/SakuraCordApp/SakuraCord/releases/latest">Download DMG</a>
    ·
    <a href="#build-from-source">Build from source</a>
    ·
    <a href="docs/README.md">Documentation</a>
    ·
    <a href="https://roadmap.sakuracord.app">Roadmap</a>
  </p>
</div>

---

## A Discord client that belongs on macOS

SakuraCord preserves the visual language and familiar rhythm of Discord, then
reimagines the experience through Liquid Glass and native macOS design instead
of wrapping the web app in an Electron runtime.

The result keeps Discord's familiarity while looking and behaving like a native
Mac app.

<table>
  <tr>
    <td width="50%" valign="top">
      <h3>🌸 Native by design</h3>
      SwiftUI surfaces, real macOS windows, menus, shortcuts, settings, and
      Liquid Glass presentation.
    </td>
    <td width="50%" valign="top">
      <h3>💬 The whole conversation</h3>
      Servers, channels, DMs, forums, threads, rich messages, reactions,
      mentions, drafts, and a fast quick switcher.
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <h3>🎙️ Voice and video</h3>
      Native device controls, Opus audio, H.264 video, voice-server migration,
      and DAVE support.
    </td>
    <td width="50%" valign="top">
      <h3>✨ Rich Discord content</h3>
      Embeds, Components V2, stickers, uploads, custom emoji, slash commands,
      forum posts, and media previews.
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <h3>🔐 Local where it matters</h3>
      Credentials stay in Keychain, account data lives in an isolated GRDB
      store, and cached media remains on-device.
    </td>
    <td width="50%" valign="top">
      <h3>🧪 Built to be testable</h3>
      A network-disabled demo environment, rich synthetic fixtures, and
      deterministic protocol coverage make development possible without a live
      account.
    </td>
  </tr>
</table>

## Download

Download the newest
[Download the latest versioned DMG](https://github.com/SakuraCordApp/SakuraCord/releases/latest)
directly, or browse its notes and checksums on
[GitHub Releases](https://github.com/SakuraCordApp/SakuraCord/releases/latest).

| | |
| --- | --- |
| **Current release** | [Latest GitHub release](https://github.com/SakuraCordApp/SakuraCord/releases/latest) |
| **System requirement** | macOS 27 or newer |
| **Package** | [Download the latest versioned DMG](https://github.com/SakuraCordApp/SakuraCord/releases/latest) |
| **Update channel** | Signed GitHub Releases, checked automatically every six hours or manually through **Check for Updates…** |

Open the DMG and move SakuraCord into Applications. Current release artifacts
are ad-hoc signed rather than notarized, so macOS may require approval from
**System Settings → Privacy & Security** on first launch.

SakuraCord is an independent project and is not affiliated with Discord.
Discord does not provide a supported third-party platform for normal-account
clients, so compatibility can change as Discord evolves.

## Where the project stands

<table>
  <tr>
    <td width="50%" valign="top">
      <h3>✅ What's Done</h3>
      <ul>
        <li><strong>Native macOS foundation</strong></li>
        <li><strong>Everyday chat</strong></li>
        <li><strong>Rich content</strong></li>
        <li><strong>Voice and camera</strong></li>
        <li><strong>Account and local data</strong></li>
        <li><strong>Offline development</strong></li>
      </ul>
    </td>
    <td width="50%" valign="top">
      <h3>🌱 Coming Soon</h3>
      <ul>
        <li><strong>Chat and media polish</strong></li>
        <li><strong>Complete DMs and notifications</strong></li>
        <li><strong>Screen sharing and call reliability</strong></li>
        <li><strong>More personal control</strong></li>
        <li><strong>Independent windows</strong></li>
        <li><strong>Server administration</strong></li>
      </ul>
    </td>
  </tr>
</table>

See the [public roadmap](https://roadmap.sakuracord.app) for live status,
accepted community requests, and the work beyond this short overview.

## Build from source

You will need:

- macOS 27;
- Xcode 27 with Swift 6.4; and
- Git.

Clone the repository and start in the offline demo:

```sh
git clone https://github.com/SakuraCordApp/SakuraCord.git
cd SakuraCord
./script/build_and_run.sh --offline
```

The application package lives in `App/`, and the convenience workspace is
`SakuraCord.xcworkspace`.

When you deliberately want to open the normal app:

```sh
./script/build_and_run.sh run
```

That launch can restore an existing SakuraCord session from Keychain. The
offline command never contacts Discord and is the right starting point for UI
work, screenshots, and fixture-driven development.

<details>
  <summary><strong>More development commands</strong></summary>

  <br>

  | Command | Purpose |
  | --- | --- |
  | `./script/build_and_run.sh --offline-long-server-list` | Open the extended server-rail fixture. |
  | `./script/build_and_run.sh --offline-forum-performance` | Open the large forum fixture. |
  | `./script/build_and_run.sh --verify` | Package, launch offline, and verify the scoped process. |
  | `./script/build_and_run.sh package` | Stage a signed debug app without launching it. |
  | `./script/worktree_test.sh protocol` | Run the protocol package tests. |
  | `./script/worktree_test.sh app` | Run the application package tests. |
  | `./script/worktree_test.sh all` | Run the repository test matrix. |
  | `./script/ci.sh` | Run the same build entrypoint used by CI. |

</details>

## Inside the project

```text
App/                  macOS application, UI, resources, and packaging
Packages/
  DiscordProtocol/    REST, Gateway, authentication, fixtures, and models
  MessagingCore/      message composition and shared chat behavior
  MessageRendering/   Markdown, embeds, components, and presentation
  MediaPipeline/      media loading, caching, and playback
  VoiceMedia/         native voice and video transport
  SakuraCordPluginSDK permission-model plugin API
docs/                 canonical architecture, protocol, and workflow guides
script/               build, package, test, and worktree entrypoints
```

Start with the [documentation index](docs/README.md), then use the
[architecture guide](docs/ARCHITECTURE.md) or
[protocol baseline](docs/PROTOCOL_BASELINE.md) for deeper work. Concurrent
contributors should read the
[linked-worktree workflow](docs/PARALLEL_WORKTREES.md) before starting parallel
builds.

## Releases and development

Version tags drive the release workflow. A tag matching `vMAJOR.MINOR.PATCH`
builds the app, verifies its nested signatures, packages the DMG, generates and
verifies a Sparkle-signed appcast, and publishes both files through GitHub
Actions. The packaged app and native About panel use that release version, and
the downloadable archive is named `SakuraCord vMAJOR.MINOR.PATCH.dmg`.

```sh
git tag v0.1.0
git push origin v0.1.0
```

### One-time Sparkle release setup

SakuraCord pins the official Sparkle 2.9.4 Swift package. Resolve it, locate the
bundled official tools, and generate one Ed25519 keypair on a trusted maintainer
Mac:

```sh
swift package --package-path App resolve
find App/.build/artifacts -path '*/bin/generate_keys' -type f
App/.build/artifacts/sparkle/Sparkle/bin/generate_keys
App/.build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-private-key
```

Copy the printed base64 public key, back up `sparkle-private-key` in an offline
secret store, and configure these exact GitHub Actions repository secrets:

```sh
gh secret set SPARKLE_ED_PRIVATE_KEY < sparkle-private-key
gh secret set SPARKLE_ED_PUBLIC_KEY
printf '%s' 'ad-hoc-updates-are-not-notarized' | gh secret set SPARKLE_ADHOC_RELEASE_ACK
```

`SPARKLE_ED_PUBLIC_KEY` is the public value printed by `generate_keys`.
`SPARKLE_ADHOC_RELEASE_ACK` is an explicit acknowledgement of the current
distribution limitation described below. Remove the exported working copy only
after confirming the offline backup and repository secrets.

The release job fails before publishing when these secrets are absent or
malformed, when the private and public keys do not match the packaged app, when
Sparkle cannot sign the archive/feed, or when appcast, bundle, URL, version, or
nested-signature validation fails. Local, debug, and linked-worktree packages
do not embed the production feed or public key and never perform update checks.

Canonical releases check the signed feed every six hours while SakuraCord is
running and after launch when a check is overdue. Users can change automatic
checking and downloading in **Settings → General**, and those preferences
persist through Sparkle across launches. A new release opens Sparkle's standard
update alert with the complete GitHub-generated release notes. Installation is
manual by default, and the alert lets the user opt into automatically
downloading and installing future updates. The GitHub Release and signed
appcast receive the same generated Markdown body so their changelogs cannot
drift. Sparkle's standard UI reports no-update, network, download, signature,
and installation failures without crashing SakuraCord.

Current artifacts remain ad-hoc signed and are not notarized. Sparkle's EdDSA
signature authenticates the update archive and signed feed, but it does not
replace Apple Developer ID signing, hardened-runtime distribution, or
notarization. Gatekeeper behavior for an in-place update must therefore be
verified manually from an older public build before maintainers rely on the
channel; the GitHub DMG remains the fallback. The workflow does not claim that
this verification has occurred.

Treat the Sparkle private key as irreplaceable while releases remain ad-hoc
signed. Sparkle's supported Ed25519 key-rotation fallback requires Developer ID
signed application updates (and, with pre-extraction verification enabled, a
Developer ID signed DMG). Do not replace either key secret in place. To rotate,
first establish and verify a Developer ID signed/notarized transition release
using the old Sparkle key, then follow Sparkle's current key-rotation procedure
in a later release while keeping the Apple signing identity stable. If the key
is lost or compromised before that transition, stop publishing the appcast and
ship a manual-download migration rather than weakening validation.

Before proposing a change:

```sh
./script/worktree_test.sh all
git diff --check
```

Never commit credentials, cookie exports, authorization headers, account
databases, personal Discord data, or unsanitized protocol captures.

## Follow along

<table>
  <tr>
    <td align="center" width="33%">
      <h3>Discord</h3>
      Talk with the community, share feedback, and follow day-to-day project
      conversation.<br><br>
      <a href="https://discord.gg/hWNwFXkUTP"><strong>Join the server →</strong></a>
    </td>
    <td align="center" width="33%">
      <h3>Roadmap</h3>
      Browse planned work, active development, completed features, and community
      requests.<br><br>
      <a href="https://roadmap.sakuracord.app"><strong>Explore the roadmap →</strong></a>
    </td>
    <td align="center" width="33%">
      <h3>Releases</h3>
      Read release notes and download the newest packaged build for macOS.<br><br>
      <a href="https://github.com/SakuraCordApp/SakuraCord/releases/latest"><strong>Get the latest build →</strong></a>
    </td>
  </tr>
</table>

<div align="center">
  <sub>Made for macOS with Swift, SwiftUI, and a little sakura pink.</sub>
</div>
