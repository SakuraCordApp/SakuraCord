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
script/simulator.sh start [--scenario demo] [--seed 1] [--network standard|instant|lan|broadband|mobile] [--epoch ISO8601] [--freeze-clock]
script/run.sh --simulator [SCENARIO]      # starts the simulator if needed, launches the debug app signed in
script/run.sh --simulator-sign-in         # launches signed out; sign in with the email and password `world` prints
script/simulator.sh ctl world             # accounts, guilds, channels
script/simulator.sh stop
```

Debug builds launched with `--discord-simulator [PORT]` rewrite Discord hosts
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
| P+9 | Control API (simulator-only JSON) | none |

## Scenarios

`discord-simulator --list-scenarios`. All are deterministic for a seed and epoch.

| Scenario | World |
| --- | --- |
| `demo` | Two servers (one boosted to level 3), DMs, a group DM, friends, ~440 messages with media, embeds, polls, threads, forums, stickers and system messages |
| `long-server-list` | `demo` + 16 small servers (param `extra`) |
| `server-rail` | `demo` + servers up to 150 (param `servers`) |
| `chat-performance` | `demo` + a server whose #general has 5,000 messages (params `messages`, `content=text\|media\|voice\|files`, `pins`) |
| `forum-performance` | `demo` + a #feedback forum with 5,000 posts (param `posts`) |
| `friends-performance` | `demo` + 1,000 friends, 100 incoming, 100 outgoing requests |
| `side-chat-motion` | `demo` + #general with long threads (params `threads`, `thread_messages`) |

Bots answer slash commands and button presses (`POST /interactions`) the way
Discord runs them: INTERACTION_CREATE, the bot's reply, INTERACTION_SUCCESS.
In `demo`, Pip answers `/gamenight` and `/digest`, and its RSVP buttons update
the card.

The default epoch ("now") is the most recent Sunday 21:30 in the Mac's time
zone, which is what the demo conversation is written for; pass `--epoch` for
runs that must be identical on any day.

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
| `voice <user> join <channel> [--video]` / `leave` / `mute` / `unmute` / `deafen` / `undeafen` / `camera-on` / `camera-off` / `speak` / `quiet` | A simulated person in voice |
| `network <profile>` or `network <latency-ms> <jitter-ms> [down-Bps] [up-Bps]` | Delay, jitter and bandwidth for every host |
| `fault 429\|5xx [route] [count]` | REST faults (429s carry `retry_after` and rate-limit headers) |
| `fault gateway-drop\|gateway-reconnect\|gateway-invalid-session\|gateway-close-resumable` | Gateway drops, op 7, op 9, close 4000 |
| `clock freeze\|unfreeze\|advance <seconds>` | The simulated clock behind timestamps and IDs |
| `script <name> key=value...` | Live streams for benchmarks: `timeline-stress`, `unread-churn`, `presence-churn`, `rail-badges` |
| `log [LEVEL]` / `routes` / `world` | Loud failures (unknown routes and assets), implemented routes, world summary |

The default `standard` profile adds a fixed 35 ms per request and per Gateway
message plus broadband transfer time, with no jitter, so every run, benchmarks
included, sees the same timings. `instant` turns delay off; `lan`, `broadband`
and `mobile` add jitter.

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
  event (captured field order; uncaptured fields are dropped).
- The Gateway encodes as the client asks (`encoding=etf|json`,
  `compress=zstd-stream|zlib-stream`), choosing ETF term types from the
  captured `etf` tags.

## Parity

`discord-sim-parity check` (also run by `swift test` and CI) drives a fresh
simulator over real HTTP and WebSocket connections and compares responses,
Gateway frames, ETF term types and event order with the captured shapes:
fields, kinds, nullability and order. A kind or omission the capture only saw
for the same field in a similar object elsewhere is reported as unverified,
not as a failure; so is anything inside a value captured only as null or
empty. `--break SUBJECT` corrupts one response to show the suite failing.

To refresh shapes, capture the official client with the `discord-cdp-research`
skill (writes only in the SakuraCord Testing server), then:

```sh
swift run --package-path Packages/DiscordSimulator discord-sim-parity extract <session>/report/capture.jsonl... --out Packages/DiscordSimulator/Sources/SimulatorKit/Resources/Shapes
```

Only kinds, field names, order and ETF tags are kept; raw captures stay out of Git.
`POST /auth/login` is not captured (the official client can't sign in without
its owner) and follows Discord's documented response.
