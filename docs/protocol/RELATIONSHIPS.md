# Friends and relationships

[Protocol index](../PROTOCOL_BASELINE.md)

## Owners and checks

| Contract | Source | Representative checks |
| --- | --- | --- |
| Records, full read, mutations | [DiscordRESTRelationships.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordRESTRelationships.swift) | [RelationshipContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/RelationshipContractTests.swift) |
| Human CAPTCHA replay | [DiscordCaptchaChallenge.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordCaptchaChallenge.swift); [HumanCaptchaStore.swift](../../App/Sources/SakuraCord/Models/HumanCaptchaStore.swift) | [RelationshipContractTests.swift](../../Packages/DiscordProtocol/Tests/DiscordProtocolTests/RelationshipContractTests.swift); [HumanCaptchaTests.swift](../../App/Tests/SakuraCordAppTests/HumanCaptchaTests.swift) |
| Friends projection | [FriendsState.swift](../../App/Sources/SakuraCord/Models/FriendsState.swift); [AppModelFriends.swift](../../App/Sources/SakuraCord/Models/AppModelFriends.swift) | [FriendsListPolicyTests.swift](../../App/Tests/SakuraCordAppTests/FriendsListPolicyTests.swift) |

Reference: official stable 633029 (FriendsStore, RelationshipStore and the
relationship action modules), observed against the first-party client in
October 2026. Pinned Paicord agrees on routes and types; its older accept body
and CAPTCHA delivery are superseded. Pinned Swiftcord has no equivalent.

## Records and loading

Types are 1 friend, 2 blocked, 3 incoming, 4 outgoing and 5 implicit. READY
lists every record, sometimes without an embedded user; a record keeps its
identity until the user hydrates. READY_SUPPLEMENTAL `merged_presences.friends`
and private `PRESENCE_UPDATE` feed the shared private presence cache; absent
presence and another user's Invisible both read as offline. There is no
per-friend presence request.

`GET /users/@me/relationships` runs at most once per Gateway connection, started
by the first All or Pending view; Online and Add Friend use READY. A record
changed by Gateway while the read is in flight keeps its newer state, and a new
READY discards the result.

`RELATIONSHIP_ADD` keeps stored nickname/since/note when omitted or null; `RELATIONSHIP_UPDATE`
replaces them; `RELATIONSHIP_REMOVE` deletes the record. Mutations answer 204
without a body and Gateway often arrives first, so responses never write records.

## Mutations

| Action | Request | `X-Context-Properties` location |
| --- | --- | --- |
| Send request | `POST /users/@me/relationships` `{"username":…,"discriminator":null}` (legacy tag: number), optional `note` | Add Friend |
| Accept | `PUT /users/@me/relationships/{user}` `{"confirm_stranger_request":false}` | Friends |
| Remove, cancel, decline | `DELETE /users/@me/relationships/{user}` | Friends |
| Block | `PUT /users/@me/relationships/{user}` `{"type":2}` | ContextMenu |
| Unblock | `DELETE /users/@me/relationships/{user}` | none |

Each is one attempt. Code 80013 on accept asks the user to confirm; only that
confirmation repeats it with `true`. Codes 80000–80007, 80013, 30002, 30059 and
30078 show Discord's copy and stay operation-scoped; account restrictions such as
40002 and 40068 keep the safety circuit. A 404 DELETE means another session
already removed it. Bulk pending clears, ignore/unignore, game relationships and
suggestions are not implemented.

Add Friend trims, drops one leading `@` from an untagged name and accepts
Discord's username pattern or a legacy `name#0000` tag, at most 37 characters.
Personalized requests accept an optional note, limited to 120 UTF-16 code units
before normalization. Newlines become spaces, surrounding whitespace is trimmed,
and an empty result is omitted from the POST body. The original normalized note
is retained through CAPTCHA replay. Both READY and live relationship events
carry the note; full reads use the same decoder. Pending shows outgoing notes
and reveals incoming notes on “View Request”, a local action with no REST call.
The note is request metadata, separate from the account's private user note.
Acceptance causes Discord to emit a DM `MESSAGE_CREATE` of type 67 containing
the note; the client must not send a duplicate message. This was observed when
accepting a personalized request in SakuraCord and in the official client.

These note contracts were observed in both saved accounts on 2026-10-08 against
the same official stable build, with module237309 supplying the UTF-16 validation
and normalization rules. Notes and their reveal state remain in session memory
and clear on account teardown.

## CAPTCHA

A 400 with `captcha_key` and a supported `captcha_service` (hCaptcha, reCAPTCHA,
reCAPTCHA Enterprise with `user_flow` as its action, Turnstile) on a send,
accept or block route is presented for human completion. The identical request
and context is replayed once with `X-Captcha-Key`, plus the original
`captcha_rqtoken` and `captcha_session_id` as `X-Captcha-Rqtoken` and
`X-Captcha-Session-Id`. Cancellation, an empty solution, an account change or a
second challenge ends the attempt. Unknown services keep the safety circuit.
hCaptcha uses its SDK; other services render their vendor's explicit widget in
an ephemeral discord.com-origin web view that never receives credentials.
Mocked transport tests cover every service; no live challenge has been served,
so live widget compatibility for each service remains unverified.
