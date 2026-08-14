<div align="center">
  <img src="Brand/Banners/SakuraCord-README-Header.svg" width="1200" alt="SakuraCord">

  <p>A fast, native Discord client shaped around SwiftUI, macOS, and the way desktop chat should feel.</p>

  <p>
    <a href="https://github.com/SakuraCordApp/SakuraCord/releases/latest"><picture><source media="(prefers-color-scheme: dark)" srcset="https://shieldcn.dev/github/release/SakuraCordApp/SakuraCord.svg?label=Release&amp;mode=dark&amp;size=sm"><img alt="Latest release" src="https://shieldcn.dev/github/release/SakuraCordApp/SakuraCord.svg?label=Release&amp;mode=light&amp;size=sm"></picture></a>
    <a href="https://discord.gg/hWNwFXkUTP"><picture><source media="(prefers-color-scheme: dark)" srcset="https://shieldcn.dev/discord/online-members/hWNwFXkUTP.svg?variant=branded&amp;mode=dark&amp;size=sm"><img alt="Discord online members" src="https://shieldcn.dev/discord/online-members/hWNwFXkUTP.svg?variant=branded&amp;mode=light&amp;size=sm"></picture></a>
    <a href="https://roadmap.sakuracord.app"><picture><source media="(prefers-color-scheme: dark)" srcset="https://shieldcn.dev/badge/Roadmap-D9578B.svg?logo=ri%3AFaMap&amp;logoColor=white&amp;mode=dark&amp;size=sm"><img alt="Roadmap" src="https://shieldcn.dev/badge/Roadmap-D9578B.svg?logo=ri%3AFaMap&amp;logoColor=white&amp;mode=light&amp;size=sm"></picture></a>
  </p>

  <p>
    <a href="https://github.com/SakuraCordApp/SakuraCord/actions/workflows/ci.yml"><picture><source media="(prefers-color-scheme: dark)" srcset="https://shieldcn.dev/github/ci/SakuraCordApp/SakuraCord.svg?workflow=ci.yml&amp;branch=main&amp;label=Build&amp;variant=secondary&amp;mode=dark&amp;size=xs"><img alt="Build status" src="https://shieldcn.dev/github/ci/SakuraCordApp/SakuraCord.svg?workflow=ci.yml&amp;branch=main&amp;label=Build&amp;variant=secondary&amp;mode=light&amp;size=xs"></picture></a>
    <a href="#build-from-source"><picture><source media="(prefers-color-scheme: dark)" srcset="https://shieldcn.dev/badge/macOS-27-18181B.svg?logo=apple&amp;mode=dark&amp;size=xs"><img alt="Requires macOS 27" src="https://shieldcn.dev/badge/macOS-27-18181B.svg?logo=apple&amp;mode=light&amp;size=xs"></picture></a>
    <a href="https://www.swift.org"><picture><source media="(prefers-color-scheme: dark)" srcset="https://shieldcn.dev/badge/Swift-6.4-F05138.svg?logo=swift&amp;mode=dark&amp;size=xs"><img alt="Built with Swift 6.4" src="https://shieldcn.dev/badge/Swift-6.4-F05138.svg?logo=swift&amp;mode=light&amp;size=xs"></picture></a>
  </p>

  <p>
    <a href="https://github.com/SakuraCordApp/SakuraCord/releases/latest">Download DMG</a>
    ·
    <a href="#build-from-source">Build from source</a>
    ·
    <a href="docs/README.md">Documentation</a>
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
      <h3>💬 Native conversations</h3>
      Guild text and announcement channels, DMs and group DMs, voice-channel
      chat, threads, and forum-post conversations share one native timeline.
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <h3>🎙️ Voice and video</h3>
      Native device controls, guild voice, direct-message calls, Opus audio,
      H.264 video, voice-server migration, and DAVE support.
    </td>
    <td width="50%" valign="top">
      <h3>✨ Rich Discord content</h3>
      Embeds, Components V2, modals, stickers, GIFs, uploads, custom emoji,
      slash commands, and media previews where Discord capability gates allow.
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
      Network-disabled fixtures, deterministic protocol coverage, performance
      scenes, and sanitized diagnostics support development without a live
      account.
    </td>
  </tr>
</table>

## Download

Download the
[latest versioned SakuraCord DMG](https://github.com/SakuraCordApp/SakuraCord/releases/latest)
directly, or browse its release notes and assets on
[GitHub Releases](https://github.com/SakuraCordApp/SakuraCord/releases/latest).

| | |
| --- | --- |
| **Current release** | [Latest GitHub release](https://github.com/SakuraCordApp/SakuraCord/releases/latest) |
| **System requirement** | macOS 27 or newer |
| **Package** | [Download the latest versioned DMG](https://github.com/SakuraCordApp/SakuraCord/releases/latest) |
| **Update channel** | Sparkle-signed feed hosted on GitHub Releases; production builds check every six hours or through **Check for Updates…** |

Open the DMG and move SakuraCord into Applications. Current release artifacts
are ad-hoc signed rather than notarized, so macOS may require approval from
**System Settings → Privacy & Security** on first launch.

SakuraCord is an independent project and is not affiliated with Discord.
Discord does not provide a supported third-party platform for normal-account
clients, so compatibility can change as Discord evolves.

## Where the project stands

The current source implements the core native-client path without claiming
complete parity with Discord:

| Area | Current implementation |
| --- | --- |
| **Navigation and conversations** | Server and channel navigation with guild text and announcement channels, DMs and group DMs, voice-channel chat, threads, and forum-post conversations. |
| **Messages** | Paginated history, sending, editing, deleting, replies, attachments with per-tier size checks and an opt-in Catbox/Litterbox link fallback, drafts, reactions, typing state, read state, and unread navigation. |
| **Discord content** | Embeds, custom emoji, stickers, GIF search, slash commands and autocomplete, Components V2, dynamic component choices, and interaction modals. Availability is capability-gated where Discord requires it. |
| **Voice, video, and media** | Native guild voice and video, direct-message calls, device selection, Opus and H.264 transport, DAVE integration, media previews, playback, and a bounded on-device media cache. |
| **macOS integration** | Native windows, menus, settings, notifications and sounds, notification deep links, Keychain-backed credentials, and account-scoped local persistence. |
| **Development and support** | Network-disabled fixtures, focused performance scenes, deterministic protocol tests, and an exportable bounded diagnostics log that sanitizes sensitive content. |

Some Discord features and administration surfaces are still intentionally
absent or incomplete. The plugin SDK and separately signed plugin-host target
are scaffolding only: the host does not currently load plugins. See the
[public roadmap](https://roadmap.sakuracord.app) for the live status of planned,
active, completed, and community-requested work.

## Build from source

You will need:

- macOS 27;
- Xcode 27 with Swift 6.4; and
- Git.

Clone the repository and start in the offline demo:

```sh
git clone https://github.com/SakuraCordApp/SakuraCord.git
cd SakuraCord
./script/install_git_hooks.sh
git config --local --get core.hooksPath
./script/build_and_run.sh --offline
```

Installing the repository hooks is a required one-time setup step for every
fresh clone, including clones used by coding agents. The installer is
idempotent and refuses to overwrite a different existing Git hooks path. The
verification command above must print `.githooks`.

The application package lives in `App/`, and the convenience workspace is
`SakuraCord.xcworkspace`.

The repository-managed pre-commit hook checks the exact staged index snapshot,
and pre-push independently checks the committed tips being pushed plus any
remaining staged Swift snapshot before contacting the remote. Both use
checksum-verified SwiftFormat and SwiftLint binaries at the repository-pinned
versions, cached under the ignored `.build/` directory. Existing SwiftFormat
drift and every SwiftLint violation are rejected under the checked-in strict
policy.

When you deliberately want to open the normal app:

```sh
./script/build_and_run.sh run
```

That launch can restore an existing SakuraCord session from Keychain. The
offline command never contacts Discord and is the right starting point for UI
work, screenshots, and fixture-driven development.

### Insecure local credential mode (debug only)

For temporary local work that must survive repeated ad-hoc rebuilds without
Keychain prompts, opt into the explicitly insecure debug credential store:

```sh
export SAKURACORD_INSECURE_DEBUG_CREDENTIALS=1
./script/build_and_run.sh run
```

This is a build-time opt-in, so keep the variable set for every debug rebuild
that should use local credentials. The first launch copies the existing
credential from Keychain and can prompt once. A normal networking-enabled
launch can then restore the authenticated session from the local copy. A launch
with `SAKURACORD_DISABLE_DISCORD_NETWORK=1` may perform the migration, but stays
signed out by design.

The copied credential is an unencrypted mode-`0600` file under:

```text
~/Library/Containers/dev.sakuracord.SakuraCord/Data/Library/Application Support/SakuraCord/InsecureDebugCredentials/
```

Its parent directory is mode `0700`, and it is outside the Git checkout, but it
is still readable by other processes running as the same macOS user and by
local disk inspection. Never enable this mode on a shared or production
machine, never copy that directory into the repository, and never attach its
contents to logs or bug reports. Release and update-enabled packages reject the
flag.

When finished, unset `SAKURACORD_INSECURE_DEBUG_CREDENTIALS` to return to the
normal Keychain store. The local copy is intentionally retained until you
remove the `InsecureDebugCredentials` directory above, so do that after the
debug session no longer needs to survive rebuilds.

<details>
  <summary><strong>More development commands</strong></summary>

  <br>

  | Command | Purpose |
  | --- | --- |
  | `./script/build_and_run.sh --offline-long-server-list` | Open the extended server-rail fixture. |
  | `./script/build_and_run.sh --offline-forum-performance` | Open the large forum fixture. |
  | `./script/build_and_run.sh --offline-chat-performance` | Open the large native-timeline fixture. |
  | `./script/build_and_run.sh --offline-incoming-private-call` | Open the incoming direct-message call fixture. |
  | `./script/build_and_run.sh --verify` | Build the app bundle, launch it offline, and verify the scoped process. |
  | `./script/build_and_run.sh package` | Stage an ad-hoc signed debug app without launching it. |
  | `./script/test.sh protocol` | Run the protocol package tests. |
  | `./script/test.sh app` | Run the application package tests. |
  | `./script/test.sh all` | Run the configured first-party package and application test matrix. |
  | `./script/code_quality.sh check` | Run the complete pinned SwiftFormat and SwiftLint policy used by CI and both Git hooks. |
  | `./script/code_quality.sh fix --staged` | Format only staged Swift files and re-stage them; refuses files with additional unstaged edits. |
  | `./script/code_quality.sh fix --files App/Sources/Example.swift` | Format only explicitly selected tracked Swift files. |
  | `./script/test_code_quality.sh` | Verify commit/push rejection, snapshot diagnostics, correction, and dirty-work preservation. |
  | `./script/ci.sh` | Run CI's code-quality check, credential scan, dependency resolution, and application build. |

</details>

## Inside the project

```text
App/                         macOS app, AppKit bridges, state, settings,
                             packaging, and the inert plugin-host executable
Packages/
  SakuraCordModels/          domain values, messages, commands, interactions,
                             and provider events
  DiscordProtocol/          provider contract, REST, Gateway, authentication,
                             scheduling, and offline fixtures
  SakuraCordPersistence/    account-scoped GRDB storage, migrations, and drafts
  MessageRendering/         Discord Markdown parsing and attributed-content
                             planning
  MediaPipeline/            media caching plus native voice/video signaling,
                             transport, capture, playback, Opus, H.264, and DAVE
  SakuraCordPluginSDK/      plugin manifest, capability, and permission contracts
  DaveKit/                  Swift wrapper over the vendored libdave/MLS code
Brand/                      canonical logos, banners, and brand metadata
Config/                     application entitlements
docs/                       canonical architecture, protocol, and workflow guides
script/                     build, package, quality, and test entrypoints
```

SwiftPM manifests are the build source of truth; `SakuraCord.xcworkspace` is a
convenience entry point. Start with the [documentation index](docs/README.md),
then use the [architecture guide](docs/ARCHITECTURE.md) or
[protocol baseline](docs/PROTOCOL_BASELINE.md) for deeper work.

## Releases and development

Version tags drive the release workflow. A tag matching `vMAJOR.MINOR.PATCH`
builds the app, verifies its nested signatures, packages the DMG, generates and
verifies a Sparkle-signed appcast, publishes reviewed pre-made release notes,
and sends the reviewed pre-made announcement to Discord. The packaged app and
native About panel use that release version, and
the downloadable archive is named `SakuraCord.vMAJOR.MINOR.PATCH.dmg`.

Before creating the tag, write `Releases/vMAJOR.MINOR.PATCH.json` manually or
ask an agent to draft it, review the complete text, and commit it with the
release. The file is deliberately ordinary source data—local tooling may help
write it, but CI performs no AI inference or copy generation. Follow the
[detailed GitHub release-note guide](docs/RELEASE_NOTES_STYLE.md) and the
[concise Discord announcement guide](docs/DISCORD_RELEASE_ANNOUNCEMENTS_STYLE.md),
and review both drafts before saving them:

```json
{
  "schemaVersion": 1,
  "tagName": "v0.1.3",
  "githubDescription": "SakuraCord v0.1.3 adds ...\n\n## Feature area\n\n- Added ...\n\n**Full Changelog:** [v0.1.2...v0.1.3](https://github.com/SakuraCordApp/SakuraCord/compare/v0.1.2...v0.1.3)",
  "discordAnnouncement": "**Specific feature headline 🌸**\n\n**Highlights**\n- A user-facing feature"
}
```

Validate it before tagging:

```sh
node script/release_automation.mjs validate-copy \
  --input Releases/v0.1.3.json --tag v0.1.3
git add Releases/v0.1.3.json
git commit -m "Prepare v0.1.3 release copy"
git tag v0.1.3
git push origin main v0.1.3
```

The installed pre-push hook repeats this validation only for pushed
`refs/tags/v*` refs and rejects a missing, malformed, or mismatched release-copy
file from the tagged commit. The release job independently repeats the same
guard before packaging, so bypassing or missing local hooks cannot publish an
unreviewed release.

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

### One-time Discord release setup

Store the Discord bot credential and destination IDs as repository secrets as
well; none belong in workflow YAML, logs, release assets, or source:

```sh
gh secret set DISCORD_BOT_TOKEN
printf '%s' '1528180315233714368' | gh secret set DISCORD_RELEASE_CHANNEL_ID
printf '%s' '1528177363995590795' | gh secret set DISCORD_UPDATES_ROLE_ID
```

The bot needs permission to view and send in the configured channel and to
mention the updates role. Pre-made text cannot add arbitrary mentions:
`allowed_mentions` admits only the configured role, and additional mention
syntax in the reviewed copy is neutralized. The action derives the
`SakuraCord vX.Y.Z` embed title from the tag and generates the role mention and
**View release** button; only the embed description is authored in the release
copy.

The release workflow validates the tag's committed file, publishes its notes,
uploads the validated snapshot as `release-copy.json`, and checkpoints a
successful Discord delivery as `discord-announcement.json`. A retry therefore
reuses the exact committed copy and does not post a second announcement. The
legacy roadmap worker and generic GitHub-event notifier recognize the hidden
Action ownership marker appended by the validator and do not race this path.

The release job fails before publishing when the tag's pre-made file is absent,
malformed, or names another tag; when Sparkle secrets are absent or malformed;
when the private and public keys do not match the packaged app; or when appcast,
bundle, URL, version, or nested-signature validation fails. Discord is
deliberately last: a Discord credential or permission failure leaves the
already verified GitHub Release intact, and a manual retry resumes from its
committed copy. Local and debug packages do not embed the production feed or
public key and never perform update checks.

Canonical releases check the signed feed every six hours while SakuraCord is
running and after launch when a check is overdue. Users can change automatic
checking and downloading in **Settings → General**, and those preferences
persist through Sparkle across launches. A new release opens Sparkle's standard
update alert with the complete current GitHub Release notes. Installation is
manual by default; users may opt into automatic downloading, while Sparkle
still verifies the signed update before installation. When a maintainer edits a
GitHub Release body after publication, the release-edit workflow downloads the
unchanged DMG, regenerates and verifies its signed appcast with that current
Markdown body, and replaces only the appcast asset. Global release concurrency
keeps that refresh from racing the original release publication. The same
workflow can be dispatched manually with a release tag to repair an older feed.
Sparkle's standard UI reports no-update, network, download, signature, and
installation failures without crashing SakuraCord.

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
git diff --check
./script/code_quality.sh check
./script/test.sh all
./script/ci.sh
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
