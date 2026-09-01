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
      <h3>⚡ Blazingly fast</h3>
      Low-level APIs keep the app responsive and every timeline exceptionally
      fluid, with scrolling no other native Discord client for macOS matches.
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
</table>

## Download

Download the [latest SakuraCord DMG](https://github.com/SakuraCordApp/SakuraCord/releases/latest)
for macOS 27 or newer, open it, and move SakuraCord into Applications.

Current releases are ad-hoc signed rather than notarized, so macOS may require
approval from **System Settings → Privacy & Security** on first launch.

SakuraCord is an independent project and is not affiliated with Discord.
Discord does not provide a supported third-party platform for normal-account
clients, so compatibility can change as Discord evolves.

## Build from source

Building SakuraCord requires macOS 27, Xcode 27 with Swift 6.4, and Git.

```sh
git clone https://github.com/SakuraCordApp/SakuraCord.git
cd SakuraCord
./script/install_git_hooks.sh
git config --local --get core.hooksPath
./script/build_and_run.sh --offline
```

The hooks command must print `.githooks`. The offline demo does not contact
Discord and is the safest way to explore the app from source. Developers can
find authenticated launch modes, focused fixtures, validation commands, and
local credential guidance in the [development guide](docs/DEVELOPMENT.md).

## Repository guide

| Path | Purpose |
| --- | --- |
| `App/` | Native macOS application and plugin-host targets |
| `Packages/` | Models, Discord protocol, persistence, message rendering, media, and plugin contracts |
| `Brand/` | Logos, banners, and brand metadata |
| `Config/` | Application entitlements |
| `docs/` | Canonical architecture, protocol, testing, development, and release guides |
| `script/` | Build, test, quality, packaging, and release entry points |

SwiftPM manifests are the build source of truth;
`SakuraCord.xcworkspace` is a convenience entry point. Start with the
[documentation index](docs/README.md), then use the
[architecture guide](docs/ARCHITECTURE.md) or
[protocol baseline](docs/PROTOCOL_BASELINE.md) for deeper work.

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
