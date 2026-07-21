# Architecture

The application is a SwiftPM-backed macOS executable collected in an Xcode workspace with six feature packages plus the local DaveKit voice dependency.

- `SakuraCordModels` owns stable domain values and typed snowflakes.
- `DiscordProtocol` owns provider, credential, REST/Gateway-facing boundaries and the mock provider.
- `SakuraCordPersistence` owns account-scoped GRDB storage and migrations.
- `MessageRendering` owns native markdown and message content rendering.
- `MediaPipeline` owns public-media caching, GIF-provider interfaces, and native voice/video transport, codecs, capture, playback, and DAVE integration.
- `SakuraCordPluginSDK` owns capability and permission contracts that can later be represented in WIT.
- `DaveKit` wraps Discord's DAVE/MLS implementation for `MediaPipeline`; the app does not depend on it directly.

`AppModel` is a Main Actor observable projection of `ChatProvider` and `SakuraCordDatabase`. Views receive narrow values or the model reference, and no view constructs Discord requests directly. Its launch state is explicit: normal launch starts restoring, signed out, connecting, or in a real workspace; offline testing starts only with `--offline` or `--offline-long-server-list` and is the only mode allowed to construct `MockChatProvider`.

Within `DiscordProtocol`, `GatewaySession` is the sole owner of Gateway sockets, receive/heartbeat loops, resumable session state, compression framing, and reconnect policy. `DiscordRESTProvider` remains the owner of authenticated REST scheduling, rate-limit buckets, the safety circuit, caches, and domain-event decoding; it consumes session events rather than managing WebSocket tasks itself. Production providers own a dedicated URL session, allowing a restriction or authentication stop to cancel REST/upload tasks and Gateway together without affecting unrelated app networking.

`DiscordClientMetadata` is the single metadata source for session validation, REST, and Gateway Identify. Message nonces are Discord-epoch snowflake values owned by `SakuraCordModels`; message requests add the narrowly scoped chat-input context. The provider never stores or invents a fingerprint, installation ID, cookie, or analytics identity.

Remote typing is held by a dedicated Main Actor observable keyed by channel and user, rather than by `AppModel`'s broad observation surface. Local typing requests originate from user edits in the composer, are scheduled by `AppModel`, and still pass through `ChatProvider` into the provider's shared REST coordinator. The AppKit-backed composer editor is an isolated SwiftUI bridge used only where marked-text and modifier-key handling require native text-system state.

Authentication is a native SwiftUI flow. It obtains Discord's server-issued fingerprint, submits the password login request, presents native MFA choices, presents only Discord's hCaptcha challenge component when Discord requests one, validates `/users/@me`, and stores the resulting credential through `KeychainCredentialStore`. There is no embedded Discord login page and a normal signed-out launch has no mock guilds, channels, messages, or placeholder account. Plugins never receive the credential or its handle.

The default `.icon` source lives in `App/Packaging/SakuraCord.icon`, with `App/Packaging/SakuraCord Flower.icon` included as a self-build alternative selected through `SAKURACORD_APP_ICON`. The shell-first packaging script compiles the selected source directly with `actool` into the app bundle, so an Xcode project is not required and SwiftPM remains the clone/build source of truth.

The `SakuraCordPluginHost` executable is intentionally inert. It establishes a separate signing/process target for the future WASI runtime without loading untrusted code in the app process.
