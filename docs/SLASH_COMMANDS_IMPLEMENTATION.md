# Slash commands implementation record

Research and implementation date: 19 July 2026. Implementation status: production transport, native UI, deterministic offline fixtures, request-contract coverage, and packaged-app verification complete. No live Discord command was executed.

## Scope and safety boundary

This feature covers user-initiated chat-input application commands in the selected text-capable channel. It includes command discovery, local search and ranking, subcommands, command options, autocomplete, attachment options, one explicit execution action, interaction lifecycle reconciliation, and rendering of command-response messages.

It does not add scheduled commands, unattended execution, command replay, bulk actions, token sharing, challenge bypass, or any self-bot behavior. A command interaction is a mutation and is attempted once. An ambiguous timeout never creates an automatic second execution. CAPTCHA, verification, permission, authentication, restriction, malformed-mutation, and revoked-session responses keep the existing provider-wide fail-closed behavior.

SakuraCord remains an unofficial client. Matching a current request shape does not make the client supported or ban-safe.

## Evidence and revisions

### Official Discord material

- [Application Commands](https://docs.discord.com/developers/interactions/application-commands)
- [Receiving and Responding to Interactions](https://docs.discord.com/developers/interactions/receiving-and-responding)
- [Component Reference](https://docs.discord.com/developers/components/reference)
- [Using Modal Components](https://docs.discord.com/developers/components/using-modal-components)
- [Message Resource](https://docs.discord.com/developers/resources/message)
- [Gateway Events](https://docs.discord.com/developers/events/gateway-events)
- [Rate Limits](https://docs.discord.com/developers/topics/rate-limits)

Public documentation establishes command and option types, option constraints, the `APPLICATION_COMMAND` and `APPLICATION_COMMAND_AUTOCOMPLETE` interaction types, interaction option/resolved structures, message flags, and response-message fields. It primarily documents bot/application-facing surfaces; it does not document the normal-account command-index or `POST /interactions` client contract used by Discord's own UI.

The following current unofficial reference pages were therefore used only for fields and routes that are absent from the public developer documentation, and were checked against current public Discord client assets before adoption:

- [Application command indexes](https://docs.discord.food/interactions/application-commands)
- [Client interaction submission](https://docs.discord.food/interactions/receiving-and-responding)
- [Gateway interaction lifecycle events](https://docs.discord.food/topics/gateway-events)
- [Command-response messages](https://docs.discord.food/resources/message)

### Current official client

The clean signed-out public web bootstrap at <https://discord.com/app> was inspected on 19 July 2026. It reported web build `580156`, release hash `af6069991f1b0f884f278271a1fe36a2432d056c`, and API version 9, matching the repository-wide baseline in `PROTOCOL_BASELINE.md`. Its public production JavaScript was downloaded and inspected statically. No credentials, cookies, authorization headers, messages, personal data, installation identifiers, or authenticated traffic were captured.

The locally installed Discord desktop renderer was signed in but visibly modified by Equicord. It was excluded from protocol evidence and no command was executed in it. A clean signed-in official session was not available. The user-supplied official-client screenshots provide the visual/interaction reference, while the clean public build provides the current request, cache, ranking, and lifecycle implementation evidence. No live Discord request was made during this research.

The supplied screenshots establish these presentation states:

1. `/` opens a command picker above the composer with a left application/category rail, a Frequently Used section, command name and description, application attribution, and a highlighted keyboard selection.
2. Selecting a command keeps the existing message-input bar in place and turns its text region into an inline command field editor with application identity, command path, completed option chips, and the focused option.
3. Choices, entity results, autocomplete values, and available optional options appear in the attached glass panel above the input while the caret remains in the native text editor.
4. Up/Down navigate the attached results, Left/Right cross option boundaries only when the caret is already at the corresponding text boundary, Tab advances or accepts, and native selection/editing remains available inside the field.
5. Attachment options use the same contextual panel, native file picker, and composer drop target rather than replacing the input with a separate form.
6. A successful invocation produces a normal timeline row headed with `used /command`, followed by the application's response content, including Components V2.

### Paicord

- Repository: <https://github.com/llsc12/Paicord>
- Revision: [`694761c1938b73bb60bd58942674dfe73aab1135`](https://github.com/llsc12/Paicord/commit/694761c1938b73bb60bd58942674dfe73aab1135), committed 14 July 2026.

The revision models command option kinds 1 through 11, choices, autocomplete flags, localization, numeric and string bounds, contexts, integration types, command versions, `CreateInteraction`, autocomplete Gateway events, interaction metadata, and message type 20. Its chat-input message view is a useful rendering reference.

The reviewed revision does not implement end-user command-index discovery, command search/ranking, option editing, autocomplete submission, or chat-input command execution. Its `CreateInteraction` payload is a model rather than a complete user action path. It therefore supplies type/parsing and response-rendering evidence, not a production execution contract.

### Swiftcord v1 and DiscordKit

- Swiftcord v1 revision: [`14465d927ebe1ba34b3befa00f9365fad7b56eb9`](https://github.com/SwiftcordApp/Swiftcord/commit/14465d927ebe1ba34b3befa00f9365fad7b56eb9), committed 29 May 2024.
- DiscordKit revision: [`2d42c69cafe592300a1a9d3a307bf485294026c7`](https://github.com/SwiftcordApp/DiscordKit/commit/2d42c69cafe592300a1a9d3a307bf485294026c7), committed 13 October 2023.

Swiftcord v1 has no slash-command composer or client execution path. DiscordKit models bot-side command registration, received interactions, interaction responses, and legacy message interaction metadata. Those structures are useful historical decoding references but do not establish a current normal-account discovery or execution contract.

## Sanitized official-client findings

### Command indexes and invalidation

The current public client defines and uses these API v9 routes:

- `GET /guilds/{guild_id}/application-command-index`
- `GET /channels/{channel_id}/application-command-index`
- `GET /users/@me/application-command-index`
- `GET /applications/{application_id}/application-command-index`
- `/channels/{channel_id}/application-commands/search` is also defined for server-backed search, but the normal slash picker is built from the index stores when available.

An index contains `applications`, `application_commands`, and `version`. The client joins commands to application descriptors, flattens subcommand groups/subcommands into display commands, carries the root command and subcommand path for execution, applies permissions/context/integration filters, and stores a server version per target.

Cold misses are coalesced per target. A `202` response waits five seconds before another read. A `429` waits the server-provided `retry_after`. The public implementation caps one index-fetch sequence at three created requests. Failure sets a short local retry gate. `GUILD_APPLICATION_COMMAND_INDEX_UPDATE`, user-application changes, locale changes, command bad-version failures, and guild/channel deletion invalidate the relevant cached indexes.

SakuraCord will use the same target model and invalidation signals, but all authenticated reads remain routed through its existing shared scheduler and safety circuit. It will not speculatively fetch every application-specific index or use the search endpoint when the loaded context/user indexes can answer the picker.

### Search, sections, and frecency

The official picker combines context commands, user-installed commands, and built-ins, then filters unavailable commands before ranking. Subcommands are displayed as a full localized path. Application identity remains a first-class section descriptor.

The public client persists command usage in `ApplicationCommandFrecencyV2`, merges it with server-synchronized frecency settings, and keys guild-specific usage as `command_id:guild_id`. Usage is recorded when the command is explicitly invoked, not when highlighted. Frequently Used is a ranked prefix section ahead of ordinary results.

SakuraCord will keep a small account-scoped local frecency store and never fabricate remote settings. Ranking order is: exact full-path/prefix match, token-prefix match, contiguous fuzzy match, local frecency, server `global_popularity_rank`, then stable localized name/application ordering. Empty-query results show Frequently Used followed by application sections. The architecture retains unknown command/option raw values so a future type can decode safely; unsupported future option editors remain visibly unavailable rather than being transmitted incorrectly.

### Command and option construction

The current client builds option payloads with `{type, name, value}`. Subcommand paths wrap the leaf options from the inside out with `{type, name, options}`. Attachment option values are zero-based indexes into `data.attachments`. Autocomplete sends the same option tree but marks the active option with `focused: true`.

Supported option types are:

| Raw type | Editor and transmitted value |
| --- | --- |
| 1 Subcommand | Structural wrapper with nested `options`. |
| 2 Subcommand group | Structural wrapper with nested `options`. |
| 3 String | Text, fixed choice, or remote autocomplete value; applies min/max length. |
| 4 Integer | Locale-aware editor normalized to an integral JSON number; applies choices/min/max/autocomplete. |
| 5 Boolean | Explicit true/false choice. |
| 6 User | Resolved user/member snowflake. |
| 7 Channel | Resolved channel snowflake filtered by `channel_types`. |
| 8 Role | Resolved role snowflake, including `@everyone` where valid. |
| 9 Mentionable | Resolved user or role snowflake. |
| 10 Number | Locale-aware finite JSON number; applies choices/min/max/autocomplete. |
| 11 Attachment | Staged upload index; descriptor appears in `data.attachments`. |

Discord has no distinct slash-command `Member` option type: type 6 is `User`, and a guild invocation resolves both the user and its guild-member projection. The current command-option schema also exposes no server-defined default-value field. A choice named “Default” is an ordinary application-defined choice, not a client prefill. SakuraCord therefore does not invent defaults; it will preserve future root fields losslessly and leave an unknown future editor unavailable until its wire contract is known.

Required options remain ahead of optional options. Choices and autocomplete are mutually exclusive. Only string, integer, and number options issue remote autocomplete. Validation happens before transmission and preserves omission versus an empty value.

User/role/channel resolvers first use the selected guild/channel caches already owned by `AppModel`. The existing lazy guild-member subscription/search path may supply user results for an explicit query; identical in-flight searches are coalesced and superseded queries are cancelled. Resolver UI never fans out across unrelated guilds.

The role resolver uses the complete cached guild-role catalog rather than deriving roles from the currently visible members, so unassigned roles and the guild's default role remain selectable. A settled non-empty user/mentionable query may issue one bounded guild-member search (limit 25); results are cached for the active session, identical pending queries are coalesced, and focus/query changes cancel superseded work.

### Autocomplete

For one focused autocomplete option, the official client posts:

```json
{
  "type": 4,
  "application_id": "...",
  "guild_id": "...",
  "channel_id": "...",
  "session_id": "...",
  "data": {
    "id": "...",
    "name": "...",
    "type": 1,
    "version": "...",
    "options": [{"type": 3, "name": "query", "value": "sa", "focused": true}]
  },
  "nonce": "..."
}
```

The current public client avoids a duplicate request for the same option/query, caches choices per option/query, associates each pending request with its nonce, and applies a three-second client timeout. `APPLICATION_COMMAND_AUTOCOMPLETE_RESPONSE` carries the result choices and nonce; failure clears the pending state. Integer autocomplete values are normalized back to numbers.

SakuraCord will debounce settled text changes, cancel superseded local tasks, coalesce identical in-flight requests, cache the bounded result set for the active command session, and ignore late responses whose nonce is no longer active. It will not automatically retry autocomplete mutations.

Autocomplete preflight validates and emits the focused option plus already entered values, but deliberately omits later required options that the user has not reached yet. Final execution continues to reject every missing required option before transmission.

### Execution and attachments

The official client stages command attachments before execution, then queues exactly one command mutation. The outer `guild_id` is the conversation where the command is invoked. The inner `data.guild_id` is present only when the command record itself is guild-scoped; a global command invoked in a guild must not copy the conversation guild into that inner field:

```json
{
  "type": 2,
  "application_id": "...",
  "guild_id": "...",
  "channel_id": "...",
  "session_id": "...",
  "data": {
    "version": "...",
    "id": "...",
    "name": "root-command-name",
    "type": 1,
    "options": [],
    "application_command": {},
    "attachments": []
  },
  "nonce": "...",
  "analytics_location": "slash_ui"
}
```

The outer `guild_id` is omitted for private-channel invocations. The inner `data.guild_id` is omitted for global commands and contains the command record's guild only for guild-scoped commands. `application_command` is the root command returned by the index. The current client can include `section_name` and `source` for non-slash entry points; ordinary chat input uses the `slash_ui` analytics location and does not need SakuraCord to invent unrelated analytics identifiers.

### 19 July 2026 live failure correction

A single user-initiated global command invocation in a guild returned HTTP 400 with Discord code `10005` (`Unknown integration`). SakuraCord stopped its network session immediately and did not retry. The request builder had incorrectly copied the invocation guild into inner `data.guild_id`, falsely presenting a global command as guild-registered. The builder now derives inner `data.guild_id` only from the command index record while the outer `guild_id` continues to describe the invocation context. A regression contract test covers this global-command-in-guild case. No follow-up live request was made automatically.

Attachment staging uses the existing channel attachment reservation flow, one unauthenticated storage `PUT` per file, and then embeds `{id, filename, uploaded_filename}` descriptors in command data. SakuraCord will reuse its existing safe reservation/upload implementation; uploads complete before the single interaction mutation. Removing an attachment option removes the matching staged upload.

### Interaction lifecycle and responses

The official client tracks an interaction by nonce through queued, created, success, and failure states:

- `INTERACTION_CREATE` associates the server interaction ID with the pending nonce.
- `INTERACTION_SUCCESS` completes the pending interaction.
- `INTERACTION_FAILURE` completes it with a reason/code.
- `MESSAGE_CREATE` carrying the same nonce also reconciles the pending command.
- A returned modal is delivered through the existing interaction modal event path.

Current modal responses use Label containers (type 18) around text inputs, selects, file uploads, radio groups, checkbox groups, and checkboxes (types 4, 3/5/6/7/8, 19, 21, 22, and 23). SakuraCord decodes both those controls and legacy action-row text inputs, presents them through the native modal sheet, uploads selected files through the established reservation path, and sends one type-5 interaction response with the original nonce and Gateway session ID.

The command POST returns 204; the response message arrives through Gateway and is decoded through the normal message path. Deferred responses use the loading flag and later message updates. Ephemeral responses use the ephemeral flag and are visible only to the initiating session. Follow-ups are ordinary application messages and remain in normal timeline ordering.

Message type 20 is a chat-input-command response. Current messages can carry `interaction_metadata`; older/current compatibility payloads can also carry the deprecated `interaction` object containing the invoked command name. The client route `GET /channels/{channel_id}/messages/{message_id}/interaction-data` can supply full command data, but SakuraCord will not issue that read merely to decorate every row. It will render the name already present in message metadata or pending nonce reconciliation and use a neutral `used an app command` fallback when the server did not include it.

Command attribution uses the same connector/layout component as reply context, with command-specific author and command-token content. Ephemeral visibility and dismissal appear beneath the response content, matching Discord's hierarchy; ephemeral rows are session-local and are not persisted to message history.

## Reference comparison and SakuraCord choices

| Area | Current official client | Paicord `694761c...` | Swiftcord v1 / DiscordKit | SakuraCord choice |
| --- | --- | --- | --- | --- |
| Discovery | Context/user/application indexes with versioned cache and invalidation. | Models only; no discovery path. | No client discovery. | Versioned coalesced context/user indexes through shared REST transport. |
| Picker | App sections, Frequently Used, permission filtering, localized flattened subcommands. | None. | None. | Native SwiftUI overlay matching supplied states; local account-scoped frecency and deterministic fuzzy ranking. |
| Options | Types 1–11, choices/bounds, resolvers, remote autocomplete, attachments. | Models types 1–11. | Bot-side historical models. | Typed domain values, preflight validation, cached resolvers, unknown-type preservation. |
| Autocomplete | One type-4 interaction per distinct active query; nonce-correlated Gateway result; three-second timeout. | Event model only. | Received interaction model only. | Same payload/lifecycle; debounce/coalescing; zero automatic retries. |
| Execute | One queued type-2 `POST /interactions`, current session ID, command version/root data, nonce. | Payload model but no execution call flow. | No user-client execution. | One mutation through central scheduler, no retry after any ambiguous result. |
| Attachments | Stage first; descriptors in `data.attachments`; option value is descriptor index. | General attachment upload support. | Historical message attachments. | Reuse existing reservation + storage PUT; never place local URLs in interaction JSON. |
| Reconciliation | Nonce-keyed create/success/failure/message events; optimistic type-20 row. | Message type/metadata models. | Legacy interaction metadata. | Pending state keyed by nonce; server messages/updates are authoritative; no duplicate execution. |
| Rendering | `used /command`, application attribution, normal/deferred/ephemeral/follow-up components. | Basic type-20 renderer. | Legacy response fields. | Extend the shared DTO/domain/message renderer; Components V2 remains in the existing renderer. |

## Planned architecture boundaries

### Models

`SakuraCordModels` owns loss-tolerant command-index types, stable application/command/option identities, typed option values, autocomplete choices, execution drafts, interaction lifecycle state, and message interaction metadata. Raw integer-backed command and option types preserve forward compatibility.

### Protocol provider

`ChatProvider` exposes command index loading, autocomplete, execution, and a slash-command capability. `DiscordRESTProvider` owns index caches, in-flight coalescing, version invalidation, session-ID access, attachment staging, request construction, and nonce lifecycle. `MockChatProvider` supplies deterministic indexes, every option type, autocomplete, success/deferred/ephemeral/failure examples, and request counters without Discord networking. `SignedOutChatProvider` keeps the capability unavailable.

All authenticated routes continue through the existing transport, conservative scheduler, header application, logging, and safety circuit. The interaction route does not create a one-off `URLSession` path.

### App model and composer

`AppModel` is the network boundary for views. It stores loaded command index presentation data and pending lifecycle events. A dedicated main-actor observable command-composer model owns the active command, typed option edits, local validation, resolver/autocomplete tasks, and local frecency. It resets on channel/account change and never survives logout.

`ComposerView` remains the stable composition surface. Entering a leading `/` opens an attached command picker above the unchanged input bar. Selecting a command replaces only the input bar's text region with an inline command path, completed option chips, and one caret-bearing option field; it does not swap the composer for a separate form. The existing AppKit text bridge receives a narrow callback for Up/Down/Left/Right/Tab/Escape/Return command routing, while SwiftUI remains the source of truth for typed values, selection, active command, and focus.

The picker uses the same shared rail bookmark component and one continuous lazily rendered `ScrollView` document pattern as the emoji picker. Frequently Used is always the first browsing section, with local frecency and server popularity evidence capped to five commands; remaining application sections are alphabetized. Picker rows, inline chips, resolver results, autocomplete choices, attachment actions, validation, and progress state all retain stable IDs. Native `fileImporter`, drag/drop, focus, accessibility labels, caret movement, and text selection are preserved.

### Message pipeline

History and Gateway message creation share one decoder for `interaction`, `interaction_metadata`, `application`, type 20, flags, embeds, components, and attachments. Updates merge only fields present. The row header renders the invoking user and command path when known, then delegates response content to the existing rich-message pipeline. Loading and ephemeral flags receive compact visible labels; follow-ups remain ordinary application messages.

## Request budgets

| Explicit scenario | Maximum authenticated request budget |
| --- | --- |
| Open slash picker, warm valid index | 0. |
| Open slash picker, cold guild context | 1 guild-index GET plus 1 user-index GET; each target is coalesced. A server `202`/`429` sequence may create at most 3 GETs for that target, following the server delay. |
| Open slash picker, cold DM context | 1 channel-index GET plus 1 user-index GET under the same per-target bound. |
| Type/filter/select locally | 0. |
| Resolve from already loaded members/roles/channels | 0. |
| Explicit uncached member query | At most 1 existing member-search/subscription action for the settled query; superseded local work is cancelled and identical work coalesced. |
| Remote command autocomplete | 1 type-4 interaction per settled distinct option/query; 0 automatic retries. |
| Execute with no attachment | 1 type-2 interaction; 0 automatic retries. |
| Execute with attachments | 1 reservation, 1 storage PUT per file, then 1 type-2 interaction; 0 retry of the final mutation. |
| Submit a returned modal | 1 type-5 interaction; with files, 1 reservation and 1 storage PUT per file first. The final mutation is not retried. |
| Gateway create/success/failure/message/update | 0 REST requests. |
| Render `used /command` | 0 by default; no automatic interaction-data lookup. |
| Validation failure, missing required option, unsupported future type | 0. |

An index read may follow Discord's bounded read retry behavior because it is idempotent. Autocomplete and execution are mutations and use one attempt. A `429` pauses the shared scheduler according to server data, but SakuraCord does not replay a command interaction after that response. The user can edit and explicitly initiate a new action after the failure is surfaced; the app does not present it as an automatic retry of the same pending command.

## Test and rollout requirements

All automated tests run with Discord networking disabled and sanitized synthetic IDs.

- Decode indexes with applications, permissions, localizations, subcommands, every option type, unknown types, malformed child entries, and version changes.
- Flatten subcommands without losing the root execution command or localized display path.
- Verify deterministic ranking, application sections, guild-scoped frecency, usage recording only on execution, and stable row identity.
- Verify required-before-optional ordering, add/remove optional values, choices, numeric/string bounds, channel filters, resolver identity, and omission versus empty value.
- Verify autocomplete debounce/coalescing/cache, focused option construction, nonce correlation, stale response rejection, timeout, failure, and zero retry.
- Verify exact type-2 method/route/body/headers, session ID provenance, root command/version, subcommand nesting, snowflake values, attachment indexes/descriptors, and one final mutation.
- Verify request budgets for cold/warm indexes, repeated picker openings, repeated local search, autocomplete, attachments, execution, failure, and cancellation.
- Verify Gateway index invalidation and interaction create/success/failure/autocomplete decoding.
- Verify response messages, optimistic reconciliation, loading update, ephemeral label, follow-up ordering, modal handoff, deletion, malformed metadata, and Components V2 rendering.
- Verify keyboard navigation, focus restoration, IME/marked-text safety, Return-to-send behavior, Escape hierarchy, VoiceOver labels, file importing, and drag/drop in the packaged offline app.

Production slash-command capability remains closed until request-contract and request-budget tests pass. No live smoke test is authorized by this implementation task. If a later user explicitly authorizes one, it must be one command in one private test channel on a disposable account, with an expected single interaction mutation and immediate stop on any unexpected response or event.

## Rollback

The feature is additive: remove the slash-command capability and composer integration to return to the existing message composer. Command index/frecency data is non-credential account-scoped cache data and can be discarded. No Keychain format, message database schema, Gateway session identity, or normal message-send contract is changed.
