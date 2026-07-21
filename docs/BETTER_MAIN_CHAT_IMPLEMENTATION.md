# Better Main Chat View implementation record

Last updated: 2026-07-21

## Scope and rollout state

The rich-message decoding and presentation pipeline is enabled by default. It does not issue authenticated Discord requests while rendering, scrolling, opening cached media, revealing spoilers, navigating loaded replies, or displaying decoded embeds and components.

New normal-account interaction capabilities remain independently disabled in `DiscordRESTProvider`. `ChatProvider.supports(_:)` is the rollout authority and defaults to `false`; a UI control cannot infer support from its payload. The offline provider enables synthetic GIF, sticker, component, and modal flows for deterministic UI coverage. These fixtures exist only in explicit offline testing mode and are never supplied by the signed-out or authenticated production providers.

Production gates still closed:

- Component buttons and message selects.
- Returned modals and modal submission.
- Remote user, role, mentionable, and channel choice search.
- GIF search and trending.
- Guild sticker catalog and sticker sending.

Premium purchase, billing, and entitlement flows are intentionally excluded.

## Evidence baseline

| Reference | Revision/build | Finding used by SakuraCord |
| --- | --- | --- |
| Paicord | `694761c1938b73bb60bd58942674dfe73aab1135` | Attachment mosaics, legacy embeds, and stickers are useful rendering references. Its Components V2 view is explicitly unsupported, so it is not an interaction-contract reference. |
| Swiftcord v1 | `14465d927ebe1ba34b3befa00f9365fad7b56eb9` | Historical attachment, embed, and sticker presentation only. It has no current Components V2 contract. |
| Discord stable desktop | `0.0.401`, installed build inspected 2026-07-17 | Build identity was confirmed locally. No authorized sanitized component/GIF/sticker request capture was performed during this implementation, so production interaction gates remain closed. |
| Discord public documentation | Message Resource, Component Reference, Interactions | Field types, component ordering, flags, and app-facing structures inform loss-tolerant decoding. Public app interaction documentation does not establish the normal-account client submission contract. |

Emoji-picker follow-up, 2026-07-18:

- The pinned Paicord generated settings schema confirms that favorite emoji field 5 is an ordered repeated string list, message emoji frecency is field 6, and reaction emoji frecency is the distinct field 13. Swiftcord v1 does not implement the current settings-backed ordering.
- Current stable Discord screenshots supplied from the authorized account show favorites in server order and Frequently Used as at most two nine-item rows. SakuraCord now preserves field-5 order, ranks only field-6 entries by Discord's computed score, and caps the section at 18.
- Discord's Emoji Resource documents `GET /guilds/{guild.id}/emojis` and warns that emoji routes have unusual per-guild rate limits. SakuraCord therefore does not eagerly fan out across every guild: entering a guild section while scrolling queues one cache-aware read, processes visible guilds serially, and cancels the picker queue when it closes.

Documentation consulted:

- <https://docs.discord.com/developers/resources/channel#channel-object-channel-structure>
- <https://docs.discord.com/developers/resources/message>
- <https://docs.discord.com/developers/topics/threads>
- <https://docs.discord.com/developers/components/reference>
- <https://docs.discord.com/developers/interactions/receiving-and-responding>
- <https://docs.discord.com/developers/topics/rate-limits>

### Guild identity and conversation-access follow-up (2026-07-21)

- The shared history and Gateway message decoder now retains the message's
  `member` object. Main-chat names prefer the cached guild member and fall back
  to that message-local member, so guild nicknames and the highest-positioned
  nonzero role color are available without fetching a profile. The member list
  uses the same top-role color rule and intentionally ignores Nitro display-name
  gradients for now.
- Channel access is calculated from the bootstrapped guild permissions plus the
  cached `@everyone`, collective role, and member overwrites in Discord's
  documented order. Reading requires both `VIEW_CHANNEL` and
  `READ_MESSAGE_HISTORY`; channel sending requires `SEND_MESSAGES`; thread
  sending requires `SEND_MESSAGES_IN_THREADS`, with locked threads limited to
  members who can manage threads. Unknown member-role state remains a checking
  state instead of guessing.
- The pinned Paicord revision `694761c1938b73bb60bd58942674dfe73aab1135`
  resolves authors from its member cache or the message-local member, prefers
  `nick`, and selects the first colored role in descending role order. The
  pinned Swiftcord v1 revision
  `14465d927ebe1ba34b3befa00f9365fad7b56eb9` likewise uses message-member
  nicknames and local overwrite evaluation. SakuraCord follows those data paths
  while retaining its existing shared models and cached role catalog.
- Discord's Message Resource states that history requires `VIEW_CHANNEL` and
  that missing `READ_MESSAGE_HISTORY` yields no messages; Create Message
  requires `SEND_MESSAGES`. Its Permissions documentation supplies the
  overwrite order and implicit permission behavior. Gateway message events
  carry the guild member object used by the decoder.
- Hidden-channel presentation uses the channel object's existing
  `last_message_id` metadata to derive the last-message date and time from the
  Discord snowflake. This does not load or expose the hidden message itself.
- Request budget: zero additional requests. Rendering a nickname/color and
  evaluating access or the hidden-channel timestamp use the existing message,
  member, role, guild, and channel payloads. No profile fan-out, message read,
  or permission probe was added, and no live-account request was made for this
  change.

## Implemented presentation contract

- History responses and `MESSAGE_CREATE` share the same decoder. `MESSAGE_UPDATE` merges only fields present in the event. Rich sibling arrays are lossy at the individual-object boundary, so a malformed future embed, attachment, sticker, or component cannot discard the surrounding message.
- Persisted message blobs decode all newly added fields with empty or nil defaults; no database schema migration is required.
- `IS_COMPONENTS_V2` messages render their component tree instead of legacy content/embeds. Component `attachment://` references resolve against the decoded message attachments.
- Components V2 thumbnails retain their alt text and spoiler state; type-13 file components decode Discord's `file` field (not the gallery/thumbnail `media` field) and render as compact attachment rows.
- Components V2 unfurled media retains Discord-populated proxy URLs, dimensions, content types, placeholders, animation flags, and attachment identifiers. Single-media layouts use those dimensions instead of a 16:9 fallback, so container media remains edge-to-edge without synthetic letterboxing. Discord's current Component Reference documents these response-populated fields; the 2026-07-19 official-client screenshots supplied for this fix confirm the intrinsic media and container sizing. The pinned Paicord and Swiftcord v1 revisions above do not implement Components V2 rendering.
- Legacy content order is text, attachments, embeds, components, stickers, thread summary, reactions, and delivery state.
- Link previews use decoded server embeds. SakuraCord does not scrape message links or issue an unfurl request.
- Media mosaics display every item. Counts 1–10 use the documented hero/balanced patterns; higher counts continue in adaptive three-item rows. Inline video tiles do not create an `AVPlayer`; the player is created only in the explicit media viewer.
- Custom emoji parsing and rendering use the cached `MessageDocument`. Composer and editor text systems replace complete custom-emoji tokens with attributed attachments only after marked IME text ends, while selection and clipboard serialization retain the exact raw token.
- URL buttons are ordinary links. Custom-ID components are enabled only when the provider capability is enabled, permit one pending request per control, and never retry automatically. Premium buttons are visibly unavailable.
- Thread opening replaces the member inspector, preserves the parent timeline, performs one explicit history load, paginates one request at a time, and never joins or creates a thread.
- Thread attachments reuse the normal composer and provider upload contract:
  file selection or drag-and-drop populates the same attachment strip, and the
  existing `SendMessageDraft.attachmentURLs` pipeline reserves and uploads each
  file before creating the message at `/channels/{thread.id}/messages`. This adds
  no thread-specific route, header, retry, or speculative request behavior.
- Reply previews navigate only to an already loaded row. Missing sources show “Original unavailable” and cause no search request.
- Stickers render aspect-fit within a compact 112-point bound. Components V2 containers measure their actual rendered title/control width, clamp at 520 points, and omit the accent bar entirely when `accent_color` is absent.

## Request budgets and failure rules

| Explicit action | Maximum request budget |
| --- | --- |
| Component/select | One POST; no automatic retry, including timeout or `429`. |
| Modal submit | One POST, plus one attachment reservation and one PUT per chosen file when the verified contract requires files. No automatic retry. |
| Thread open/pagination | One history GET per explicit load. |
| GIF search | One debounced, cancellation-aware provider GET per settled query. Selection sends one message whose content is the selected media URL. |
| Sticker catalog | At most one coalesced cached provider read per guild. Selection sends one message action with `sticker_ids`. |
| Emoji guild section | Zero requests for a fresh memory/disk cache; otherwise one existing guild-emoji GET when that section becomes visible. Visible misses are loaded serially and deduplicated per guild. |
| Normal upload | One reservation, one PUT per file, then one message POST. |
| Thread upload | Same as a normal upload: one reservation, one PUT per file, then one message POST to the thread channel ID. |

Uploads may be cancelled before final submission by cancelling their task. A timeout from the final message mutation is shown as “Waiting for confirmation — do not resend”; SakuraCord waits for nonce/Gateway reconciliation and does not offer a duplicate-send retry. The current URLSession upload callback reports per-file start and completion; byte-level delegate progress can be added without changing the public progress model.

### Explicit failed-send retry (2026-07-19)

Messages that fail with a definite non-timeout error now retain their original draft and offer one explicit user-triggered retry. The retry reuses the original nonce; `POST /channels/{channel}/messages` now includes `enforce_nonce: true`, which Discord's current Create Message documentation defines as returning the earlier message instead of creating a duplicate when the same sender and nonce are seen within the deduplication window. Timeout/ambiguous results remain in “Waiting for confirmation” and deliberately do not expose retry.

This is one additional message attempt only when the user clicks Retry. Attachment retries repeat the existing reservation/upload sequence before the deduplicated final message mutation. The existing Paicord revision `694761c...` and Swiftcord v1 comparison recorded in `GATEWAY_TYPING_IMPLEMENTATION.md` remain the baseline for nonce construction; neither existing baseline supplied a conflicting failed-row UI flow. The locally installed Discord desktop shell was build `0.0.401`, but its remotely delivered client module was not present in the application bundle, so the public Discord Create Message contract is the authoritative evidence for the new deduplication field. No live-account request was made for this change.

## Gate promotion checklist

Promote one `ChatCapability` at a time only after all of the following are recorded:

1. A sanitized current official-client call flow from an authorized private test server, including method, route, body shape, required session metadata, status, response/event order, and exact request count.
2. Comparison with the pinned Paicord and Swiftcord revisions, noting when they do not implement the operation.
3. Request-contract and request-budget tests using mocked transport, including cancellation, restriction, malformed response, timeout, `429`, and proof of zero automatic mutation retries.
4. One manual user-initiated smoke test on an account whose loss is acceptable. Any unexpected request, status, payload, or Gateway event leaves the capability disabled.

Never capture or commit authorization headers, tokens, cookies, message content, personal data, installation identifiers, fingerprints, or unsanitized traffic.
