# Sticker picker protocol research

This is the persistent evidence record requested for the native sticker-picker
implementation. It is intentionally a dated, feature-specific research record;
the durable production contract must also be reflected in
`PROTOCOL_BASELINE.md` once the observations are complete.

## Observation environment

- Date: 3 September 2026 (Europe/Kyiv)
- Official client: `/Applications/Discord Official Fresh 2026-08-14.app`
- Official client identity observed through CDP: Discord `0.0.407`, Electron
  `42.7.1`, Chrome `148.0.7778.280`, CDP protocol `1.3`
- CDP endpoint: local loopback port `9229`; the page target was the authenticated
  `#general` channel in Testing Server 2.
- UI interaction: Computer Use against the exact official-client application
  path above.
- Scope guard: every picker interaction and account mutation is confined to
  Testing Server 2. Captures retain only sanitized route/body shape and status;
  credentials, cookies, authorization values, personal payloads, message text,
  and raw account/guild/channel/sticker identifiers are not retained.

At attachment time, the official sticker picker was open in Testing Server 2.
The accessibility tree exposed the Stickers tab, a Search field, the sticker
table, a Frequently Used sidebar entry, and server sidebar entries. The visible
server sections followed the same order as the server sidebar entries: Testing
Server 2, then the other eligible guilds in their displayed sequence.

## Loading stickers

Fresh frontend reload under an already-attached CDP page session established
the split source of sticker data:

- The Gateway reconnects at
  `wss://gateway.discord.gg/?encoding=etf&v=9&compress=zstd-stream`. The initial
  binary Ready/Guild Create stream carried the guild state. No per-guild sticker
  REST request was issued during reload or when opening a guild section; the
  guild sticker catalogue therefore comes from the Gateway guild payloads.
- The first sticker-picker open after reload issued
  `GET /api/v9/sticker-packs?locale=en-GB` and received HTTP 200. This supplies
  Discord's standard sticker packs. The live response held 14 packs and 361
  stickers. Pack records contained `id`, `sku_id`, `name`, `description`,
  ordered `stickers`, `cover_sticker_id`, and `banner_asset_id`; sticker records
  contained string `id`, `name`, `tags`, `description`, `asset`, and `pack_id`,
  plus numeric `type`, `format_type`, and `sort_value`.
  `cover_sticker_id` identifies the sticker artwork used for that pack's
  sidebar icon; the first pack sticker is the bounded fallback when the cover
  is absent from the usable catalogue.
- The same open issued `GET /api/v9/users/@me/settings-proto/2` and received a
  JSON object whose sole key was `settings`, containing the base64 frecency
  protobuf. This supplies favourite sticker IDs and persisted sticker frecency.
- Rendered static sticker assets used
  `GET https://media.discordapp.net/stickers/<STICKER_ID>.webp?size=240&quality=lossless`
  in the picker and size 56 for its small preview. Rendered Lottie stickers used
  `GET https://discord.com/stickers/<STICKER_ID>.json`. The newly sent timeline
  sticker used the same media host at size 320.
- Closing and reopening an already-loaded picker issued only missing media
  reads. The catalogue, pack, and settings reads are session-cached.

## Sending a sticker

A normal click on one Testing Server 2 sticker closed the picker immediately
and issued exactly one request:

- `POST /api/v9/channels/<CHANNEL_ID>/messages`, HTTP 200.
- JSON keys, in the observed serialization order:
  `mobile_network_type`, `content`, `nonce`, `tts`, `flags`, `sticker_ids`.
- Values: `mobile_network_type: "unknown"`, `content: ""`, one Discord-epoch
  nonce, `tts: false`, `flags: 0`, and a one-element `sticker_ids` array.
- `enforce_nonce` was absent.
- Decoded `X-Context-Properties` was `{ "location": "chat_input" }`.
- The successful response and Gateway echo rendered the sticker as a normal
  sticker-only message in Testing Server 2.

## Favourite add/remove and ordering

Right-clicking a usable guild sticker opened the expression-picker context menu
with Favourite Sticker, Copy Sticker ID, and Copy Sticker Image Link. Choosing
Favourite Sticker issued one
`PATCH /api/v9/users/@me/settings-proto/2` and received HTTP 200. The request
JSON contained only `settings`; the response JSON likewise contained only the
complete merged `settings` value. The full response changed top-level protobuf
field 3 from an empty length-delimited value to a container whose repeated
field 1 held the sticker ID as one packed eight-byte fixed64 value. The picker
immediately gained a Favourites sidebar category and placed the newly added
sticker first.

Right-clicking that item then exposed Unfavourite Sticker. Choosing it issued
the same PATCH and received HTTP 200. Its request was an exact two-byte partial
protobuf: top-level field 3, wire type 2, empty payload (base64 length 4). The
response was the complete merged settings proto with the same empty field 3.
The Favourites category disappeared immediately. This confirms mutations send
a partial type-2 settings proto and the server response supplies the full merged
state.

A second ordering study then added three Testing Server 2 stickers in this
sequence: `mid rizz moments`, `peace`, `gay middy moments`. After the third add,
the partial field-3 container held one packed field-1 payload of exactly 24
bytes (three fixed64 IDs) in that same oldest-to-newest insertion order. The
Favourites section displayed the same three names left-to-right in that exact
order. A full official-client restart followed by a fresh settings-proto GET
preserved the order exactly. These three are being kept temporarily for the
required two-client implementation verification and must all be removed before
the goal is complete.

## Frequently Used source and ordering

The section is not a message-history query and opening or browsing it sends no
history/search request. It is built from top-level field 4 of the type-2
settings proto, filtered through stickers that the current Gateway guild
catalogues or standard pack catalogue can resolve.

Field 4 is a repeated map-entry container. Each map key is a sticker snowflake
encoded as fixed64. Each value carries total uses (field 1), up to ten retained
recent-use timestamps (packed field 2), stored frecency (field 3), and the
stored recency-weight sum (field 4). Direct decoding of the observed proto
reproduced each stored score exactly with this algorithm:

1. Take at most the first ten retained timestamps.
2. Weight each use by whole-day age: 0–3 days = 100; 4–15 = 70; 16–30 = 50;
   31–45 = 30; 46–80 = 10; older = 1.
3. `frecency = ceil(totalUses * sum(weights) / sampledUseCount)`.
4. Sort descending by computed frecency, retaining protobuf insertion order for
   equal values; filter IDs that cannot be resolved to an available sticker;
   show the first nine (three rows).

For the visible pre-send sample, the decoded order and displayed order agreed:
`hmm` (18,237), `best rizz moments` (5,170), `peace` (3,139), `Cat Slur`
(2,848), the two standard `Wave` stickers (1,360 and 756),
`why is clown a freak` (682), then lower-scored available stickers after
unresolvable IDs were filtered. Sending `mid rizz moments` recorded a new local
use and moved it into the visible section at position eight, rather than simply
placing it first. It changed that entry from 12 total uses, a stored score of
130, and a stored weight sum of 108 to 13 uses, score 270, and weight sum 207;
the formula gives `ceil(13 * 207 / 10) = 270`.

No settings PATCH was issued synchronously with the message POST. The next
favourite action flushed the dirty sticker frecency together with the favourite
field: its partial request contained top-level field 3 (10-byte payload for the
one favourite) and field 4 (4,733-byte payload). Removing the temporary
favourite then sent only the two-byte empty-field-3 patch.

The field-4 writer must retain every unmodified map entry byte-for-byte and
preserve unknown fields on the selected entry. Reconstructing all entries from
only the four understood fields discarded server-owned wire data; an attached
3 September SakuraCord diagnostic log captured that implementation issuing a
6,477-byte JSON PATCH ten seconds after a successful sticker send and receiving
HTTP 400. The targeted raw-preserving mutation keeps the observed partial-patch
contract without weakening the transport safety stop that correctly reacts to
the rejected account mutation.

After that flush, a complete official-client frontend restart reconnected the
Gateway and opening the picker fetched fresh `/sticker-packs` and
`/users/@me/settings-proto/2` responses. Field 3 was empty, field 4 still held
the updated 13-use/270-score value, and the visible ordering was exactly:
`hmm`, `best rizz moments`, `peace`, `Cat Slur`, Wumpus `Wave`, Nelly `Wave`,
`why is clown a freak`, `mid rizz moments`, `bart`. This proves the source of
truth is the server type-2 settings proto after a flush; process-local or
on-disk media/catalogue caches cannot override the fresh proto order.

## Verification log

- SakuraCord decoded the three temporary favourites in their persisted order
  and reproduced the clean client's nine-item Frequently Used order from the
  same account settings proto.
- The combined picker exposed guild and standard-pack sections, live search,
  an exact three-column large-sticker grid, animated raster and Lottie media,
  keyboard navigation, hover preview, and the favourite/copy context actions
  without issuing message-history searches.
- Exact request-shape, settings-codec, frecency, Gateway catalogue, and send-
  policy behavior is covered by the production protocol and app test suites.
- The final signed app at `dist/SakuraCord.app` sent the standard Wumpus
  `Wave` sticker in Testing Server 2. The picker dismissed after success and
  the resulting sticker rendered in SakuraCord's live message timeline.
- Removing each of the three temporary favourites updated SakuraCord's picker
  back to `Favorites 0`. A forced reload of the official Discord client showed
  no Favorites category, confirming cross-client reconciliation and restoring
  the account's original empty favourite state.
