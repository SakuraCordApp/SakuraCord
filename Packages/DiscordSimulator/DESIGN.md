# Discord simulator

A local stand-in for Discord that SakuraCord's real Discord layer talks to in
debug builds: REST, the Gateway (ETF + zstd-stream, like the desktop client),
the CDN, the media proxy and attachment uploads, backed by a seeded, stateful
world. It is its own Swift package and executable and does not depend on
`DiscordProtocol` or any SakuraCord package. Its wire behavior comes from
captures of the official client (`Sources/SimulatorKit/Resources/Shapes`),
never from SakuraCord's protocol code, so the app's mistakes aren't mirrored.

## Running it

```sh
script/simulator.sh start [--scenario demo] [--seed 1] [--network realistic|standard|lan|mobile|instant] [--epoch ISO8601] [--freeze-clock]
script/run.sh --simulator [SCENARIO]      # starts the simulator if needed, launches the debug app signed in
script/run.sh --simulator-sign-in         # launches signed out; sign in with the email and password `world` prints
script/simulator.sh ctl world             # accounts, guilds, channels
script/simulator.sh stop
```

Debug builds launched with `--discord-simulator [PORT]`, or relaunched from a
bundle the launch scripts recorded as a simulator launch, rewrite Discord hosts
to the simulator when a request is made (`DiscordNetworkRedirect`); data keeps
real URLs. Simulator accounts, tokens and caches live apart from real ones
(`SimulatorAccountStorage`), so a real token is never sent to the simulator.
Release builds compile the redirect out.

## Hosts and ports

The simulator binds `127.0.0.1` only. One base port `P` (default 47100):

| Port | Serves | Real host it stands in for |
| --- | --- | --- |
| P | REST `/api/v9/...` | `discord.com`, `discordapp.com` |
| P+1 | Gateway WebSocket | `gateway.discord.gg` and `*.discord.gg` resume URLs |
| P+2 | CDN | `cdn.discordapp.com` |
| P+3 | Media proxy | `media.discordapp.net`, `images-ext-*.discordapp.net` |
| P+4 | Attachment uploads | `discord-attachments-uploads-prd.storage.googleapis.com` |
| P+5 | Voice gateway WebSocket (v8) | `*.discord.media` voice servers |
| P+6 | Voice media (UDP) | the IP and port the voice server's Ready announces |
| P+7 | The simulator's own Activity page and its `/.proxy/` backend | `{application_id}.discordsays.com` (the page finds its app from the proxy ticket in its URL) |
| P+9 | Control API (simulator-only JSON) | none |

## Scenarios

`discord-simulator --list-scenarios`. All are deterministic for a seed and epoch.

| Scenario | World |
| --- | --- |
| `demo` | A medium account: `demo-lite` as its close servers and friends inside ~60–80 generated servers (many large public ones), ~100 DMs, folders, muted servers, unread and mention badges, people in voice |
| `demo-small` | A small account: ~15–25 servers, mostly small communities, few DMs and friends |
| `demo-large` | A large Nitro account: 100–200 servers, many huge, with peak activity rates |
| `demo-lite` | Two servers (one boosted to level 3), DMs, a group DM, friends, ~440 messages with media, embeds, polls, threads, forums, stickers and system messages |
| `long-server-list` | `demo-lite` + 16 small servers (param `extra`) |
| `server-rail` | `demo-lite` + servers up to 150 (param `servers`) |
| `chat-performance` | `demo-lite` + a server whose #general has 5,000 messages (params `messages`, `content=text\|media\|voice\|files`, `pins`) |
| `forum-performance` | `demo-lite` + a #feedback forum with 5,000 posts (param `posts`) |
| `friends-performance` | `demo-lite` + 1,000 friends, 100 incoming, 100 outgoing requests |
| `side-chat-motion` | `demo-lite` + #general with long threads (params `threads`, `thread_messages`) |

The account modes are generated from `Resources/Profiles`: structure-only
skeletons of real accounts (counts, states and activity rates; no names, IDs,
text or timestamps), jittered and shuffled, used only as ballpark inputs. Each
mode draws its server count and account numbers from its own ranges and its
servers from the pooled skeletons. Channel history beyond each channel's
latest message is generated on the first lookup, seeded by the channel; huge
servers report Discord's member count and make further members (the same
person for the same index) when the member list scrolls to them or a member
search (op 8) asks for them. Refresh the skeletons with
`discord-sim-profile extract <capture.jsonl>... --out FILE [--mark MARK] [--seed N]`.
Benchmark scenarios build on `demo-lite`.

Avatars and icons are drawn by `MediaGenerator` from each asset hash and its
`MediaGenerator.Art`: the hand-written people and servers each have their own
drawing, photo or initials; generated people get crowd avatars (motif, colour
and pattern from the seed) and generated servers an icon for their kind of
community. As in captured READYs and member lists, about 9% of generated people
and 3% of generated servers have none; benchmark servers never have an icon.
Accounts without an avatar load the client's default-avatar files from
`discord.com/assets/<hash>.png`; the simulator draws its own at the six paths of
the client's `DEFAULT_AVATARS` list, in that order (source: official web client
bundle), and any other `/assets/` path is a loud 404.

The account modes start the `live-activity` script with the simulator: each
generated server's messages, replies, typing, reactions, edits, deletes,
presence changes and voice joins at its measured rates (scaled up in
`demo-large`), from a seeded Poisson process, so the sequence repeats run to
run. `--param activity=off` leaves it off and `--param activity_scale=N`
scales it; `ctl script stop live-activity` stops it and `ctl script
live-activity scale=N` starts it again. Benchmark scenarios and `demo-lite`
start no script: their only activity is what a benchmark starts, on a fixed
schedule.

Bots answer slash commands and button presses (`POST /interactions`) the way
Discord runs them: INTERACTION_CREATE, the bot's reply, INTERACTION_SUCCESS.
In `demo-lite` and the account modes, Pip answers `/gamenight` and `/digest`, and its RSVP buttons update
the card.

The default epoch ("now") is the Mac's current time, so simulated timestamps
agree with the app's clock. The demo conversation is written for an evening and
keeps its times of day: its last moment is the latest 21:30 at or before the
epoch in the Mac's time zone, and its weekday words are filled in from the
dates. Pass `--epoch` for runs that must be identical whenever they run on
Macs in the same time zone.

## Control API and CLI

`script/simulator.sh ctl <command>` wraps the control API (`discord-simctl`):

| Command | Effect |
| --- | --- |
| `post <channel> <author> <text> [--embed TITLE DESC] [--reply ID] [--photo WxH]` | Posts as anyone (MESSAGE_CREATE) |
| `edit` / `delete <channel> <message>` | MESSAGE_UPDATE / MESSAGE_DELETE |
| `react <channel> <message> <author> <emoji>` / `typing <channel> <author>` | Reactions, typing |
| `nitro <user> none\|basic\|nitro\|classic` | USER_UPDATE and member updates |
| `boosts <guild> <count>` | Boost count, tier, booster `premium_since`, boost system messages |
| `presence <user> online\|idle\|dnd\|offline [status text]` | PRESENCE_UPDATE |
| `ring <caller>` | The caller joins a DM call with the signed-in user and rings them (CALL_CREATE, VOICE_STATE_UPDATE, CALL_UPDATE) |
| `voice <user> join <channel> [--video] [--chatter]` / `leave` / `mute` / `unmute` / `deafen` / `undeafen` / `camera-on` / `camera-off` / `speak` / `quiet` / `stream-start` / `stream-stop` / `sound [SOUND_ID]` | A simulated person in voice; `speak` sends generated Opus speech over RTP until `quiet`, a camera or Go Live stream sends generated H.264. `--chatter` people (and the demo's unmuted voice seats) take turns talking whenever someone real is listening; the demo's streaming seat can be watched |
| `network <profile>` or `network <latency-ms> <jitter-ms> [down-Bps] [up-Bps]` | Delay, jitter and bandwidth for every host |
| `fault 429\|5xx [route] [count]` | REST faults (429s carry `retry_after` and rate-limit headers) |
| `fault gateway-drop\|gateway-reconnect\|gateway-invalid-session\|gateway-close-resumable` | Gateway drops, op 7, op 9, close 4000 |
| `clock freeze\|unfreeze\|advance <seconds>` | The simulated clock behind timestamps and IDs |
| `script <name> key=value...` / `script stop [ID\|NAME]` / `scripts` | Start, stop and list live scripts: `live-activity` (`scale`, `seconds`) and the benchmark streams `timeline-stress`, `unread-churn`, `presence-churn`, `rail-badges` |
| `qr scan\|approve\|cancel [user]` | The phone side of QR sign-in (remote-auth gateway on the Gateway port, `?v=2`) |
| `application <guild> <user> approve\|reject [reason]` | A moderator's decision on an application to join |
| `mfa <user> <six-digit-code>\|off` | Two-factor sign-in for an account |
| `automod <guild> <keyword>...` | A keyword AutoMod rule; matching messages get Discord's blocked-content 400 (code 200000) |
| `captcha <route-substring> [count]` | Discord's captcha-required 400 on that route until retried with hCaptcha's test token |
| `log [LEVEL]` / `routes` / `world` | Loud failures (unknown routes and assets), implemented routes, world summary |

Every named network is Discord's measured answer time for each host plus a
connection's round trip. A signed-in session measured REST answers at a median
275 ms (240–780 ms) over a ~30 ms round trip, so about 245 ms is Discord's
servers, and CDN images at about 33 ms; upload storage time, Gateway and voice
delays and the bandwidth are estimates.

| Network | Round trip | Variance | Bandwidth down/up | Default for |
| --- | --- | --- | --- | --- |
| `realistic` | 30 ms (the measured home connection) | log-normal per request | 12.5 / 2.5 MB/s | demo accounts |
| `standard` | 30 ms | none: every delay at its median | 12.5 / 2.5 MB/s | benchmark scenarios, benchmark launches, parity |
| `lan` | 2 ms | Discord's own | unlimited | |
| `mobile` | 100 ms | wider | 1.5 / 0.4 MB/s | |
| `instant` | no delay at all | | unlimited | |

All are seeded, so the same seed and requests give the same delays.

`GET /control/network` lists every injected delay; two runs with the same seed
and requests list the same delays.

## Determinism

- `SeededRandom` (SplitMix64) is the only randomness source; each subsystem
  forks its own stream from the seed and a label.
- `SimulatorClock` drives timestamps and snowflakes from the epoch.
- HTTP delays draw from a stream keyed by the request and its occurrence, so
  connection reuse doesn't change them; Gateway messages keep their order.

## Rules

- Real wire behavior only: Discord routes carry no simulator-only fields;
  agent controls live on the control port.
- Unknown routes and assets fail loudly: an error status and an `ERROR` log line.
- Payloads are rendered, then conformed to the captured shape for that route or
  event (captured field order; uncaptured fields are dropped unless the
  official client's code supplies them, as listed under inferred behavior).
- The Gateway encodes as the client asks (`encoding=etf|json`,
  `compress=zstd-stream|zlib-stream`), choosing ETF term types from the
  captured `etf` tags.

## Parity

`discord-sim-parity check` (also run by `swift test` and CI) drives a fresh
simulator over real HTTP and WebSocket connections and compares responses,
Gateway and voice gateway frames, ETF term types and event order with the captured shapes:
fields, kinds, nullability and order. A kind or omission the capture only saw
for the same field in a similar object elsewhere is reported as unverified,
not as a failure; so is anything inside a value captured only as null or
empty. `--break SUBJECT` corrupts one response to show the suite failing.
The flows run on `demo-lite`, whose targets stay put; a second pass on `demo`
and `demo-large` checks the generated accounts' READY, GUILD_CREATE, lazily
generated history, threads, forum search, member list ranges, member chunks
and profiles, and the live activity that arrives meanwhile.

To refresh shapes, capture the official client with the `discord-cdp-research`
skill (writes only in the SakuraCord Testing server), then:

```sh
swift run --package-path Packages/DiscordSimulator discord-sim-parity extract <session>/report/capture.jsonl... --out Packages/DiscordSimulator/Sources/SimulatorKit/Resources/Shapes
```

Only kinds, field names, order and ETF tags are kept; raw captures stay out of Git.

## Voice and DAVE

The voice gateway (P+5) follows captures of the official client
(`Resources/Shapes/gateway.json`, `voice`): hello (`v` 8, `heartbeat_interval`
13,750 ms; the main Gateway's is 41,250 ms), Ready, the versions reply to op
16, the session description, op 15 after it and after each op 12, speaking,
the client's own op 12 for a camera or screen, heartbeats, and DAVE's first
binary ops (25 from the server, 26 from the client). Ready and the session
description carry no `seq`; sequenced messages start at 0 with `seq` first.
Discord picks H265 for the official client; the simulator answers H264, the
only codec its video generator encodes. Calls use DAVE (protocol version 1)
when the client offers it: the voice server is the MLS external sender, and
simulated people are real group members whose Opus and H.264 frames libdave
encrypts. Media (P+6) is RTP over UDP, which CDP can't see.

Inferred, not captured:

- Main Gateway resume window: a session dropped without a normal close stays
  resumable for 60 s, then ends and leaves its voice state. CDP's offline
  emulation keeps the old socket open, so Discord never sees a drop; the
  official client itself identifies afresh after about a minute of failed
  reconnects (it resumed after 30 s and gave up at 60 s).
- Voice frames that need a second person in the channel (the two accounts
  can't share one client): what the server sends about other people (ops 5,
  11, 12, 13, 18 `flags`, 20 `platform`) and DAVE transitions and commits
  (ops 21–24, 27–31). They follow the official client's voice-gateway parser
  and Discord's DAVE protocol: the first commit wins; a simulated member
  creates a new group when there is one; a transition executes after 5 s if a
  member never answers; a group left with one member starts over with op 24
  (epoch 1, no `transition_id`, as the client parses it and a live test
  showed). Op 15's `pixelCounts`, seen only on a stream connection, is left out.
- Values: SSRCs (audio, then video and RTX at +1 and +2) and a 200-message
  voice resume buffer.
- A stream's group ID is its `rtc_channel_id`, which viewers identify with;
  watching someone else's stream needs a second client.
- Media: simulated speech and video are generated (Opus, H.264 with a keyframe
  every second) and sent at 50 and 15 packets/frames per second.
- Errors the official client never lets through (it blocks the action
  itself): a timed-out member sending, reacting or joining voice; a
  non-manager posting in a locked archived thread (50083); a display name over
  32, pronouns over 40 or a bio over 300 characters; adding someone who is
  neither a friend nor a server member to a group DM, and an eleventh member.
  These follow Discord's documentation.
- Edits without `allowed_mentions` (the official client always sends it): a
  reply keeps pinging only if it did before.
- An owner retagging their own thread (no forum in the Testing server has
  tags); Discord documents it as allowed.
- Unreachable from the official client with two accounts: the error for
  someone else's or an unknown scheduled message or pre-uploaded file name;
  RATE_LIMITED (the client debounces member searches); MESSAGE_POLL_VOTE_ADD_MANY
  (voting several answers sends one MESSAGE_POLL_VOTE_ADD each); AUTH_SESSION_CHANGE
  (it needs a sign-in or another session logged out).
- REST routes the official client never called in any capture: `GET
  /users/@me/guilds` (Discord's documented partial servers and paging), `GET
  /users/@me/channels`, `GET /guilds/{id}/channels`, `/roles` and
  `/members/{id}`, `GET /channels/{id}/messages/{id}`, `PATCH
  /guilds/{id}/members/@me/nick` (the client uses `PATCH /members/@me`),
  `PATCH /users/@me/guilds/{id}/settings` (it uses the bulk route),
  settings-proto 3, `GET /experiments`, `GET /applications/{id}/widget-configs`,
  personal widgets and their image uploads (Nitro-only: the bodies, the saved
  image, its `/widget-assets/{user}/{file_id}` CDN path and the widget's
  `header` and `sections` in the save and profile responses follow the official
  client's code, added to the captured shapes by `ShapeCatalog+ClientCode`;
  `file_id` being a snowflake is inferred), `POST /attachments/refresh-urls`, and
  accepting or ignoring a message request.
- Captured routes, inferred behavior: the game catalogue is the games people
  play, ranked by catalogue order where Discord ranks by popularity; unknown
  game IDs are left out; every other game is "similar"; suggested games are
  what the user and their friends play; no simulated game has an official
  server or publishes a widget config; the shop is one category holding what
  the account wears, bought 90 days ago and never expiring, with made-up euro
  prices.
- Gateway: THREAD_MEMBER_LIST_UPDATE lists every thread member in join order;
  MESSAGE_REACTION_REMOVE_EMOJI's `burst` and `type`.
- Sign-in (`POST /auth/login`, MFA and QR remote auth) follows Discord's
  documented responses: capturing it would sign an account out.

### Vendored sources

Third-party code, fetched from upstream and never copied from `Packages/DaveKit`:

- `Sources/CDave/libdave`: [discord/libdave](https://github.com/discord/libdave)
  tag `v1.3.0/cpp` (`b5463c443df74db75a713c775b09a847621e6d62`).
- `Sources/CMLS/mlspp`: [cisco/mlspp](https://github.com/cisco/mlspp)
  `1cc50a124a3bc4e143a787ec934280dc70c1034d`, the commit libdave v1.3.0's
  vcpkg overlay port pins (not DaveKit's `fc724c3`).
- `Sources/CJSON`: [nlohmann/json](https://github.com/nlohmann/json) `v3.11.3`
  single-include headers, which MLS++'s HPKE needs.
- OpenSSL 3 comes from `krzyzanowskim/OpenSSL-Package` `3.6.5000`, the version
  the app resolves.

Each tree keeps only what `Package.swift` builds plus upstream's `LICENSE` and
`README.md`. Dropped, matching libdave's CMake with OpenSSL and without
persistent keys: `bindings_wasm.cpp`, the BoringSSL cryptor, every persisted
key-pair store except `src/mls/persisted_key_pair_null.cpp`; from MLS++, its
build files, tests, tools, `third_party` (only used with `VARIANT_COMPAT`),
`mls_ds` and `mls_vectors`. libdave's `test/external_sender.{h,cpp}` and
`test/capi/external_sender_wrapper.{h,cpp}` are kept: they are the voice
server's side of DAVE.

No upstream file is modified. SwiftPM integration adds only these files:

- `Sources/CMLS/namespace/namespace.h`: what MLS++'s CMake generates from
  `cmake/namespace.h.in`, with `MLS_NAMESPACE mlspp` as libdave's port sets.
- `Sources/CDave/include/module.modulemap`: exposes only the C headers to Swift.
- `Sources/CDave/shim/external_sender_remove.{h,cpp}`: declares the external
  sender's C API for Swift (its upstream header includes `<dave/dave.h>`, which
  a Swift importer can't resolve) and adds `daveExternalSenderProposeRemove`,
  wrapping the upstream `ExternalSender::ProposeRemove`.
- `Sources/CMLS/namespace/shim.c`, `Sources/CJSON/shim.c`: SwiftPM needs a
  source file in a header-only target.

Build settings mirror the upstream builds: `DISABLE_GREASE` for MLS++ (as
libdave's port), `WITH_OPENSSL3` for HPKE, `DAVE_STATIC` for libdave, C++17.
