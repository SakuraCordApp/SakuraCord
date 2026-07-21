# Reaction reactor previews implementation record

Observed and implemented 20 July 2026. This is a narrow, read-only addition to the existing
message-reaction UI; reaction mutations and their request bodies, routes, and reconciliation are
unchanged. No live Discord account or request was used during implementation or verification.

## References

- Discord's current public [Message Resource](https://docs.discord.com/developers/resources/message)
  documents `GET /channels/{channel.id}/messages/{message.id}/reactions/{emoji}` as returning user
  objects. Its `type` query defaults to normal reactions (`0`), and `limit` is bounded to `1...100`.
  The aggregate reaction object contains counts and current-user state but no reactor user list.
- Paicord revision
  [`694761c1938b73bb60bd58942674dfe73aab1135`](https://github.com/llsc12/Paicord/commit/694761c1938b73bb60bd58942674dfe73aab1135)
  exposes the same read in `DiscordClient+APIEndpoint.swift` as
  `listMessageReactionsByEmoji`, validates `limit` to `1...100`, and sends optional `type`,
  `after`, and `limit` query values through its shared authenticated HTTP client. Its reaction view
  does not currently call this read or show reactor avatars.
- Swiftcord v1 revision
  [`14465d927ebe1ba34b3befa00f9365fad7b56eb9`](https://github.com/SwiftcordApp/Swiftcord/commit/14465d927ebe1ba34b3befa00f9365fad7b56eb9)
  and pinned DiscordKit revision
  [`2d42c69cafe592300a1a9d3a307bf485294026c7`](https://github.com/SwiftcordApp/DiscordKit/commit/2d42c69cafe592300a1a9d3a307bf485294026c7)
  model only the aggregate `count`, `me`, and `emoji` fields and contain no comparable reactor-list
  presentation flow.
- The locally installed clean Discord desktop shell reports version `0.0.401`. Its remotely
  delivered client module is not present in the application bundle, so it did not provide an
  inspectable static call site. The public Discord contract is authoritative for this documented
  route; no authenticated official-client traffic was captured.

## SakuraCord choice and request budget

SakuraCord requests only normal-reactor users, with `type=0&limit=5`, when a reaction strip is
materialized in the lazy visible-message timeline and its message payload has no known reactors.
The reactions in one visible message are loaded serially, and an app-level limiter permits no more
than four reactor reads across simultaneously visible rows. Hover remains a coalesced fallback, not
the primary trigger. Five users are sufficient for the display contract: counts through five show
every returned avatar; larger counts show the first four avatars plus the aggregate remainder.
There is no pagination and no eager whole-history, per-channel, or hidden-row fan-out.

The read uses `DiscordRESTProvider`'s existing authenticated transport, central conservative request
slot, rate-limit headers, safety circuit, sanitized route logging, and existing bounded GET retry
policy. Successful results and in-flight tasks are keyed by channel, message, stable emoji identity,
and observed aggregate count. The cache is capped at 256 entries. A message-count change gets a new
key; concurrent identical hovers coalesce, and at most four distinct reactor reads may be in flight.
The app suppresses immediate failure reattempts for 30
seconds and bounds that failure cache to 256 entries.

| Situation | Additional reactor-list requests |
| --- | ---: |
| Message decoded or cached but not materialized in a visible row | 0 |
| First visible materialization for each uncached reaction state | 1 logical GET |
| Simultaneously visible uncached reaction states | At most 4 in flight; remaining reads wait |
| Concurrent visible-row/hover request for the same state | 0 additional |
| Warm cached row or hover | 0 |
| Same reaction after its aggregate count changes | 1 logical GET |
| Failure | Existing shared GET policy: original plus at most 1 bounded retry |

The deterministic request-contract and app-model tests assert method, encoded route, `type=0`,
`limit=5`, authorization through the shared transport, coalescing, warm-cache behavior,
count-key invalidation, stable visible-row task identity, the four-read app concurrency budget, and
a zero-request guard for impossible nonpositive counts.
