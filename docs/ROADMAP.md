# Roadmap

SakuraCord already has the native application foundation, authenticated REST and Gateway connector, offline testing mode, message interactions, typing, emoji picker, and account-scoped persistence. Native voice and camera video are also implemented, including Discord voice Gateway handling, encrypted RTP media transport, Opus/H.264 paths, device and volume controls, voice-server migration, and DAVE support. The roadmap now focuses on turning those foundations into a complete, polished daily-use client.

## Chat and communication

### Better main chat view

Implementation and rollout gates are tracked in [BETTER_MAIN_CHAT_IMPLEMENTATION.md](BETTER_MAIN_CHAT_IMPLEMENTATION.md). Fixture-backed rendering is available by default; normal-account interactions remain capability-gated until their sanitized request contracts are verified.

- Present multiple image and video attachments as responsive Discord-style grids, with correct aspect ratios, overflow counts, previews, and accessible navigation.
- Improve custom emoji rendering throughout messages, reactions, autocomplete, editing, and the picker, including animated emoji and consistent sizing alongside text.
- Render Discord embeds faithfully, including rich media, fields, authors, footers, providers, thumbnails, and interaction states.
- Add full Components V2 support with native layouts for sections, containers, separators, media galleries, files, buttons, and other component types as Discord expands them.
- Continue polishing replies, threads, stickers, GIFs, uploads, link previews, message actions, and large-history performance.

### Direct messages

- Turn the existing experimental DM support into a first-class inbox with reliable one-to-one and group-DM navigation, unread state, history loading, media, reactions, and drafts.
- Make starting or reopening a conversation feel native while deduplicating channel creation and keeping user actions explicit.
- Add DM-specific search, member details, call entry points, safety controls, and clear error recovery.

### Notifications

- Integrate macOS notifications for direct messages, mentions, replies, calls, and selected server activity.
- Support per-account, per-server, and per-channel notification preferences, mute durations, badge counts, sounds, and quiet-hour behavior.
- Deep-link notifications into the correct account, server, channel, and message without disturbing the current workspace unnecessarily.

### Screen sharing

- Add a native ScreenCaptureKit picker for displays, windows, and applications, with clear macOS permission handling.
- Support preview, source switching, quality and frame-rate controls, stream health, and an obvious stop-sharing state.
- Integrate screen-share video and optional system audio with the existing voice/video session instead of creating a parallel call stack.

## Servers, roles, and permissions

- Add role creation, editing, color/icon configuration, ordering, deletion, and member assignment.
- Build a readable permission editor for role permissions and channel/category overwrites, including inherited, allowed, and denied states.
- Show an effective-permissions explanation before applying sensitive changes, with confirmation and useful error recovery.
- Expand server administration over time with channel management, moderation surfaces, audit-log presentation, and member tools.

## Personalisation

### Settings

- Grow the current Settings scene into searchable sections for accounts, chat behavior, voice and video, notifications, appearance, accessibility, key bindings, storage, privacy, and advanced diagnostics.
- Clearly distinguish Discord-synced preferences from local SakuraCord preferences and account-specific overrides.
- Add import/export or reset tools where appropriate without exposing credentials or account databases.

### Themes

- Define a stable theme-token system for colors, materials, spacing, typography, message density, and decorative effects.
- Ship a tasteful set of built-in themes and allow safe custom themes with live preview, accessibility contrast checks, and per-account selection.
- Keep themes presentation-only so they cannot gain network, credential, or plugin capabilities.

### Profile customisation

- Add native editing for supported profile fields such as display name, pronouns, bio, avatar, banner, accent color, and per-server identity.
- Preview profile changes in SakuraCord's actual profile and message surfaces before submission.
- Handle upload progress, validation, account limits, and unsupported premium-only options clearly.

## Plugins and extensibility

- Turn the existing plugin contracts and inert host process into a sandboxed WASI-based runtime with explicit capabilities.
- Add plugin installation, updates, enable/disable controls, permission review, audit history, and failure isolation.
- Provide declarative extension points for commands, menus, message decorations, sidebar tools, and settings without giving plugins direct access to credentials or unrestricted Discord networking.
- Document and version the SDK so plugins can remain compatible as SakuraCord evolves.

## Ongoing connector quality

- Continue improving session restoration, account switching, expiry recovery, caching, pagination, and offline behavior.
- Keep REST, Gateway, voice/video, and authentication fixtures current when their underlying protocol contracts change.
- Expand accessibility, localization, diagnostics, performance testing, and graceful recovery across every feature above.
