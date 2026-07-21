# Gateway and typing implementation record

Research and implementation date: 15 July 2026. This record contains only public documentation, public source-code findings, and sanitized static observations. No Discord account, credential, cookie, authorization header, message content, personal data, installation identifier, fingerprint, or live account traffic was used.

Incident correction date: 16 July 2026. The correction used sanitized local process/network metadata from the user's authorized SakuraCord session, but did not record request bodies, credentials, message content, or personal payloads and did not make any live Discord request.

## Sources and revisions

### Official Discord material

- [Gateway](https://docs.discord.com/developers/events/gateway), including connection, heartbeat, resume, reconnect, and compression guidance.
- [Gateway events](https://docs.discord.com/developers/events/gateway-events), including Ready, Resumed, Invalid Session, and Typing Start payloads.
- [Gateway opcodes and close codes](https://docs.discord.com/developers/topics/opcodes-and-status-codes).
- [Channel resource: Trigger Typing Indicator](https://docs.discord.com/developers/resources/channel#trigger-typing-indicator).
- [Message resource: Create Message](https://docs.discord.com/developers/resources/message#create-message), including nonce semantics.
- [Rate limits](https://docs.discord.com/developers/topics/rate-limits).
- [Discord public app bootstrap](https://discord.com/app) and [stable macOS update endpoint](https://discord.com/api/updates/stable?platform=osx).

Discord's public production bootstrap was inspected without signing in on 15 July 2026. This historical snapshot reported web build `578494`, release hash `b68833777a2f23ca1a5d5ccc126dd128f572241e`, API version `9`, and `wss://gateway.discord.gg`. Public production JavaScript was inspected statically for state-machine, compression-selection, heartbeat, typing-store, and composer behavior. The clean stable macOS download redirected to Discord `0.0.399`; its Developer ID signature and notarization were verified. No authenticated renderer traffic was captured. The native client's exact Electron version was not independently established. `PROTOCOL_BASELINE.md` contains the newer repository-wide baseline.

The current web path selects JSON with `zlib-stream`; the native-codec path selects ETF with `zstd-stream`. SakuraCord deliberately selects the documented JSON/`zlib-stream` path: it is current production behavior, is supported by the Gateway, and avoids copying native-only codec and telemetry behavior that SakuraCord cannot source honestly.

### Paicord

- Repository: <https://github.com/llsc12/Paicord>
- Exact revision: <https://github.com/llsc12/Paicord/commit/694761c1938b73bb60bd58942674dfe73aab1135>
- Revision: `694761c1938b73bb60bd58942674dfe73aab1135` (15 July 2026 checkout; commit authored 14 July 2026).
- Relevant paths: `UserGatewayManager.swift`, Gateway payload/event models, zstd stream decoder, channel/input stores, and the AppKit message editor.

Paicord uses API v9 JSON with `zstd-stream`, retains session ID/resume URL/sequence, resumes after a new Hello, uses an ACK watchdog and bounded reconnect delay, and implements ten-second remote typing expiry plus an eight-second local typing window. Its implementation is a reference rather than a source of truth: the reviewed revision appears to send Identify twice, clears sequence unusually early during Resume, and does not use the documented random first-heartbeat delay.

### Swiftcord v1

- Repository: <https://github.com/SwiftcordApp/Swiftcord>
- Exact revision: <https://github.com/SwiftcordApp/Swiftcord/commit/14465d927ebe1ba34b3befa00f9365fad7b56eb9>
- Revision: `14465d927ebe1ba34b3befa00f9365fad7b56eb9` (the v1-era `main` branch, 29 May 2024).
- Gateway dependency: [DiscordKit revision `2d42c69cafe592300a1a9d3a307bf485294026c7`](https://github.com/SwiftcordApp/DiscordKit/commit/2d42c69cafe592300a1a9d3a307bf485294026c7) (13 October 2023).
- Relevant paths: DiscordKit `RobustWebSocket`, Gateway event models, zlib decompressor, typing request/store logic, and Swiftcord's message input view.

Swiftcord v1 uses JSON/`zlib-stream`, a random first heartbeat, ACK timeout recovery, resumable state, terminal close-code handling, and bounded reconnect delay. It posts an empty typing request and expires remote typers independently. Its decompressor has no explicit input/output memory bound and its session behavior predates current production; those details are not copied uncritically.

## Existing implementation assessment

The previous production Gateway was embedded in `DiscordRESTProvider`. It owned a socket plus separate receive and heartbeat tasks, always identified after Hello, did not track ACKs, did not store the Ready session ID/resume URL, did not resume, did not process Invalid Session, and handled only a server Reconnect opcode. Receive-loop failure could leave state in `backingOff` without starting a replacement connection. Reentrant task callbacks could race explicit disconnect, and repeated connection paths had no generation token preventing stale tasks from affecting a newer socket.

Gateway and REST ownership were also coupled, making deterministic session tests impractical. `TYPING_START` was subscribed to but not decoded. At the app layer, one string and one expiry task represented all typing, so a second user/channel overwrote the first. Local typing did not exist. The composer always submitted through `TextField.onSubmit`, ignored the Return-to-send setting, could not reliably distinguish Shift-Return or marked-text composition, and inserted/removed the typing row in layout.

## 15 July account-restriction incident and correction

At approximately 23:43 local time, one user-initiated guild-channel send was followed by a temporary Discord sending restriction. The same local session received HTTP 401 at 23:44. Sanitized CFNetwork metadata showed one successful Gateway upgrade and no reconnect storm, so the restriction preceded the authentication failure and was not caused by repeated Gateway connections. The old safety circuit recorded the 401 but did not stop the Gateway or cancel already queued/in-flight REST work.

The message nonce generator was the concrete malformed field. Since its introduction in repository commit `bf2ed58`, it shifted Unix milliseconds directly into Discord's snowflake layout. A normal July 2026 nonce therefore decoded against Discord's epoch to a timestamp around 2071. Discord's current public client module `195880` instead calls `fromTimestampWithSequence(Date.now(), sequence)`, whose snowflake implementation subtracts the Discord epoch (`1420070400000`) before shifting 22 bits. Paicord revision `694761c...` also subtracts the Discord epoch. The corrected generator uses `(unixMilliseconds - discordEpochMilliseconds) << 22` and a local 12-bit same-millisecond sequence. Tests decode the result back to the exact creation time and cover same-millisecond uniqueness and pre-epoch underflow.

The incident review also found two compatibility gaps that could explain why local typing was not visible in the official client: SakuraCord's authenticated REST requests lacked the normal shared client-metadata envelope, and the message request lacked the current chat-input context. REST validation, Gateway Identify, typing, and message creation now use one stable metadata source with the real locale, timezone, operating-system version, and an honest SakuraCord identity. No fingerprint, installation ID, cookie, analytics identifier, or captured value is invented. Message creation additionally sends `X-Context-Properties` for `chat_input` and the current official client's `mobile_network_type: "unknown"` fallback. The typing endpoint remains an empty POST; current production module `741961` confirms the 1.5-second initial delay, eight-second refresh window, and ten-second remote expiry.

Restriction handling is now provider-wide. HTTP 401/403, Discord verification/restriction/revocation codes `40001`, `40002`, `40003`, `40004`, `40012`, and improper-client-metadata code `40333`, CAPTCHA fields, or a malformed mutation response open the circuit once. That operation stops the Gateway session, cancels all tasks in the provider-owned URL session, blocks requests that were queued in the scheduler, and does not retry the mutation. Only sanitized route templates, HTTP status, Discord code, rate-limit bucket, and timing are logged.

### Message-send contract comparison

| Field or sequencing | 15 July official-client snapshot (build 578494) | Paicord `694761c...` | Swiftcord v1 / DiscordKit `2d42c69...` | SakuraCord before correction | SakuraCord corrected |
| --- | --- | --- | --- | --- | --- |
| Nonce timestamp | Discord-epoch snowflake with per-ms sequence | Discord-epoch snowflake; low bits zero | Caller did not include a nonce in the reviewed path | Unix epoch shifted 22 bits, decoding around 2071 | Discord-epoch snowflake with local 12-bit sequence |
| Request context | `X-Context-Properties` for `chat_input` | Same location context | No equivalent in reviewed legacy path | Missing | Base64 `{"location":"chat_input"}` |
| Network field | Includes best-known `mobile_network_type` | Not present in reviewed request | Not present | Missing | `"unknown"`, the official fallback |
| Shared client metadata | Normal authenticated request layer | `X-Super-Properties` on user calls | Older user-client headers | Authorization plus generic SakuraCord UA | One consistent, honest REST/Gateway metadata source |
| Mutation retry | Queue reconciles one user action | No speculative automatic duplicate in reviewed path | Legacy path | One attempt | One attempt; restriction/malformed response stops session |

Expected request count remains one message POST per user send action on cold or warm cache, zero automatic message retries after any ambiguous result, and zero subsequent authenticated requests after a stop signal. A short local typing burst causes one separate typing POST only if the user continues editing through the official 1.5-second delay; it is never generated by draft restoration or by the send itself.

## Sanitized comparison

| Area | Current official behavior | Paicord | Swiftcord v1 | SakuraCord choice |
| --- | --- | --- | --- | --- |
| Gateway URL | API v9; web JSON/`zlib-stream`, native ETF/`zstd-stream` | v9 JSON/`zstd-stream` | JSON/`zlib-stream` | v9 JSON/`zlib-stream` |
| First heartbeat | Random fraction of Hello interval | Full interval in reviewed revision | Random fraction | Random fraction |
| Heartbeat | Current client uses an undocumented QoS heartbeat envelope; public Gateway supports opcode 1 | QoS heartbeat | Opcode 1 | Documented opcode 1 with latest sequence |
| Missed ACK | Close and recover; bounded reconnect delay | Watchdog reconnect | ACK timeout reconnect | Close once, preserve resumable state, bounded reconnect |
| Ready/Resume | Store session ID, resume URL, sequence; Ready/Resumed reset backoff | Same overall model | Stores ID/sequence; older URL behavior | Store all three; Resume opcode 6 after new Hello |
| Invalid Session | Resume if resumable; otherwise identify with cleared session | Clears on non-resumable | Clears, reconnects after randomized delay | Reconnect; preserve for `true`, clear and randomized delay for `false` |
| Close codes | Reconnect most transport failures; authentication failure terminal | Classifies protocol close codes | Explicit resumable/fatal groups | Preserve on resumable codes; clear on invalid sequence/timeout; stop on auth/configuration/protocol errors |
| Remote typing | Per-channel/per-user ten-second expiry; self ignored; message clears author | Same broad behavior | Per-user expiry, approximately nine seconds | Ten seconds, independent refresh, self ignored, message clears author |
| Local typing | Empty POST; 1.5-second debounce and eight-second throttle in current public code | Empty POST, eight-second throttle | Empty POST, eight-second throttle | Empty POST through shared REST scheduler; 1.5-second debounce and eight-second throttle |
| Typing request metadata | Authenticated normal-client request through the shared request layer; no JSON body | Shared authenticated REST client | Shared authenticated REST client | Consistent SakuraCord client metadata, shared bucket scheduler, empty body, one mutation attempt |
| Composer | Return sends and Shift-Return inserts newline in normal mode | AppKit editor, Return/Shift-Return | Older native input | Setting-aware AppKit editor; Command-Return is the explicit send shortcut when Return-to-send is disabled |

## Architecture

`GatewaySession` is the sole owner of the current WebSocket, receive loop, heartbeat task, connection generation, session ID, resume URL, sequence, reconnect attempt count, and intentional-stop flag. `DiscordRESTProvider` owns REST/cache behavior and consumes sanitized session events. It passes outbound Gateway subscription/voice payloads through the session without gaining socket ownership.

Transport, sleep/clock, and randomness are injected boundaries. Production uses `URLSessionWebSocketTask`, a cancellation-aware continuous clock, and system randomness. Tests use fake sockets, a controlled clock, and deterministic values. A per-socket streaming zlib decoder recognizes the `00 00 ff ff` flush marker across WebSocket messages, can emit multiple payloads from one message, retains inflater state, and enforces compressed-buffer and decompressed-payload bounds. Malformed or oversized compressed input fails closed rather than producing a reconnect storm.

The session state machine is:

```text
disconnected -> connecting -> awaitingHello -> identifying -> ready
                                             -> resuming   -> ready
connecting/awaitingHello/identifying/resuming/ready -> backingOff -> connecting
any state -> stopped (explicit stop or terminal close)
```

Only the active connection generation may send, transition state, or schedule recovery. Repeated `connect` and repeated Hello events are idempotent. Explicit stop increments the generation before cancelling tasks and closing the socket, so stale completions cannot reconnect.

Expected Gateway action budget:

| Scenario | Socket / outbound Gateway actions |
| --- | --- |
| Cold connection | One socket, one Identify after Hello, then one heartbeat per server interval |
| Successful resumable reconnect | One replacement socket and one Resume after its Hello; no Identify |
| Repeated `connect()` while active | Zero additional sockets or tasks |
| Repeated Hello on one socket | Zero additional Identify/Resume or heartbeat loops |
| Server Reconnect opcode | One close and one immediate replacement socket |
| Missed heartbeat ACK | One close and at most one replacement attempt after bounded backoff |
| Transport failure | One replacement attempt per bounded backoff step; at most eight attempts without Ready/Resumed |
| Explicit disconnect/logout | One normal close, zero reconnect attempts |

## Session and reconnect rules

- A new Hello starts exactly one heartbeat schedule. With valid session ID, resume URL, and sequence it sends Resume; otherwise it sends Identify.
- The first heartbeat sleeps a random fraction in `[0, interval)`; later heartbeats use the server interval. A server opcode 1 causes an immediate heartbeat and restarts the periodic cadence.
- Each heartbeat requires opcode 11 before the next scheduled heartbeat. A missing ACK closes the active socket once and enters recovery.
- Ready captures `session_id`, `resume_gateway_url`, and the dispatch sequence. Resumed and Ready reset reconnect attempts.
- Opcode 7 reconnects immediately while preserving resumable state.
- Invalid Session `true` reconnects with resumable state. `false` discards resumable state and uses a randomized one-to-five-second delay before identifying.
- Close `4004` and invalid configuration/disallowed intent codes are terminal. Invalid sequence/session-timeout codes discard resumable state. Ordinary abnormal loss preserves it while Discord may still accept Resume.
- Backoff is exponential, jittered, capped at 60 seconds, and attempt-bounded. Cancellation exits without another socket.
- Explicit disconnect/logout never enters backoff and clears local session state.

This is deliberately more conservative than the current official client's willingness to retry some protocol errors. A third-party client should fail closed when its payload or configuration is rejected.

## Typing ownership

Protocol decoding accepts documented guild payloads with `member`, tolerant top-level partial `user` data, and ID-only DM/group-DM payloads. Resolution order is payload member/user, guild-member cache, DM recipient cache, existing message authors, then current user. Unresolved IDs are omitted; SakuraCord does not invent names or avatars.

The app owns a dedicated, narrowly observed typing-state model keyed by `(channelID, userID)`. Each key has its own expiry generation/task. Repeated events refresh only that user. A message clears its author in that channel. Disconnect/logout clears all state. Switching channels changes only which channel is presented; it does not corrupt another channel's timers. Presentation is deterministic for one, two, or many users. A permanently allocated indicator row prevents composer movement, and only that small row observes high-frequency presentation changes.

Local typing begins only after a user edit, never draft restoration. It posts promptly after a 1.5-second debounce, then at most once per eight-second active window. Empty draft, send, channel change, disconnect/logout, or a non-text channel cancels pending activity. Requests use the shared authenticated REST transport/rate-limit coordinator and are not automatically retried after ambiguous mutation failure.

Expected typing request budget per channel:

| Scenario | Requests |
| --- | --- |
| Draft restoration | 0 |
| One short edit burst | 1 |
| Keystrokes during first eight seconds | 1 total |
| Continued editing beyond eight seconds | At most one additional request per eight-second window |
| Empty/send/channel switch before debounce | 0 |
| REST failure | 1 attempt; no automatic mutation retry |

## Composer behavior

- Return-to-send enabled: Return submits; Shift-Return inserts a newline.
- Return-to-send disabled: Return inserts a newline; Command-Return submits as the established macOS explicit-action convention.
- If the editor has marked text, Return is passed to the input method and never submits.
- Empty/whitespace-only content does not send unless an attachment is present.
- Keyboard and button submission share one synchronous guard, avoiding duplicate sends.
- The native editor retains standard selection, paste, undo, accessibility, multiline, and focus behavior. Focus returns after sending and follows channel/reply transitions.

## Testing strategy

Gateway tests use a fake transport, controlled clock, deterministic random source, and sanitized JSON fixtures. They cover Identify/Resume selection, Ready/Resumed state, heartbeat timing and sequence, immediate heartbeat, ACK/missed-ACK recovery, reconnect and Invalid Session, close-code classification, bounded jittered backoff, cancellation/idempotence, zlib boundaries/bounds/malformed input, and existing dispatch forwarding.

Typing tests cover guild/DM/group-DM decoding and cache resolution, self suppression, independent expiry/refresh, message clearing, channel isolation, disconnect clearing, local debounce/throttle/cancellation, restoration suppression, voice-channel suppression, and deterministic mock behavior. Composer key decisions are a pure test surface; app tests cover sending and draft persistence.

No automated test performs a Discord request. Manual verification is restricted to demo/offline modes.

## Failure, restriction, and rollback considerations

- REST `401`/`403`, verification/challenge/restriction/revocation codes, CAPTCHA fields, and malformed mutation responses open the provider-wide safety circuit. It stops Gateway, cancels the provider's REST tasks, and prevents a queued request from resuming. Typing never bypasses that coordinator.
- Rate limits remain separate from the safety stop: the shared coordinator waits for the complete server-provided cooldown and never probes or retries early.
- Gateway authentication/configuration/protocol rejection and malformed or oversized compressed data stop the session. They do not trigger speculative probes.
- Mutating typing requests have one attempt. A failure is still counted for the local throttle window, preventing keystrokes from creating a retry storm.
- The architecture is rollbackable by reverting the provider/session integration and the app typing/editor files together; no persisted schema or credential format changed.
- The offline/demo provider remains available as the operational fallback, including deterministic typing recording without networking.

## Remaining uncertainty and deliberate differences

- No authenticated clean official account session was used, so DM/group-DM typing payload variants are implemented from documented fields plus tolerant cache-based decoding rather than a fresh personal capture.
- SakuraCord uses documented opcode 1 rather than the official client's undocumented QoS heartbeat payload.
- SakuraCord uses current official web JSON/`zlib-stream`, not native ETF/`zstd-stream`. Both are accepted protocol paths; this keeps implementation inspectable and avoids claiming native official-client identity.
- The exact official setting-disabled send shortcut was not observable without an account. Command-Return is a documented project choice based on macOS convention.
- Protocol parity cannot make an unofficial normal-account client supported or safe from Discord account action. Any CAPTCHA, verification, authentication/permission anomaly, restriction response, or malformed protocol response remains a stop condition.
