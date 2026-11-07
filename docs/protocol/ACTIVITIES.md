# Activities

[Protocol index](../PROTOCOL_BASELINE.md)

## Owners and checks

[DiscordRESTEmbeddedActivities.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordRESTEmbeddedActivities.swift)
owns the shelf, launch, leave, proxy-ticket and Activity OAuth requests;
`EMBEDDED_ACTIVITY_UPDATE_V2` and READY_SUPPLEMENTAL `activity_instances` are
decoded by `GatewayActivityInstanceDTO` in
[DiscordGatewaySupport.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordGatewaySupport.swift).
[AppModelEmbeddedActivities.swift](../../App/Sources/SakuraCord/Models/AppModelEmbeddedActivities.swift)
owns running instances and the account's one hosted Activity;
[EmbeddedActivityHost.swift](../../App/Sources/SakuraCord/Services/EmbeddedActivityHost.swift)
is the Embedded App SDK parent.

The contract below was captured from the official desktop client (host 0.0.411,
web build 660103) on 3 November 2026 launching Watch Together and Chess In The
Park in a guild voice channel, Wordle in its application DM, and Watch Together
in a DM call joined by a second account, and (web build 667580) on 7 November
2026 running `/wordle` in a guild text channel and in Wordle's DM and browsing
the voice shelf and its details, then cross-checked
against the public [Embedded App SDK](https://github.com/discord/embedded-app-sdk)
2.5.0 (`b5f4774`). Paicord and Swiftcord v1 have no Activity support.

## Instances

An instance is `{application_id, instance_id, launch_id, composite_instance_id,
location, participants}`. A guild voice location is `gc-GUILD-CHANNEL`, a private
channel `pc-CHANNEL`; the composite ID is `i-INSTANCE-LOCATION`. Each participant
names a Gateway `session_id`, so one account can take part from one client while
another of its sessions does not. `EMBEDDED_ACTIVITY_UPDATE_V2` carries the whole
roster; an empty roster ends the instance. Starting another Activity removes the
session from the previous instance without a separate leave request.
READY_SUPPLEMENTAL lists the running instances of each guild under
`activity_instances`; private-channel instances arrive only as updates.

## Shelf and launch

`GET /activities/shelf?guild_id=` returns `activities` (shelf rank and platform
configuration), `applications` and per-application `assets`; the shelf tile uses
the `embedded_cover` asset, otherwise the application cover. The shelf lists
Activities by ascending `shelf_rank` and omits those whose `supported_platforms`
lacks `web`. A tile shows the cover, the icon, the name and one line of the
description, and a PROMOTED badge when the application flags include `1 << 29`
(every promoted entry in the capture had it, no other entry did). Above the
grid, Recents lists Activities from the account's application frecency, field
9 of the frecency settings proto, ranked as the client's frecency store ranks
them (uses × the mean age weight of the last ten launches); the first eight show
with View More for the rest. Opening an Activity counts a use there: one
frecency settings PATCH carrying field 9, as the official client saves when an
Activity opens. The official list also includes launched
Activities that are not on the shelf; SakuraCord lists shelf Activities only. Choosing an Activity opens its details:
the participant range (`1-N` from `max_participants`, otherwise Unlimited),
tags, the description, and In-App Purchases when `is_monetized`;
`requires_age_gate` Activities ask for age confirmation before launch.

Launching, and joining an instance already running in the channel, runs the application's entry-point command (application
command type 4) from the command indexes: `POST /interactions` type 2 with the
command's `data` envelope, empty `options` and `attachments`,
`analytics_location: "app_launcher"` and, in a voice channel, `source: "VOICE"`. Discord
answers with `INTERACTION_SUCCESS` and the instance update containing the
caller's session. A command whose handler is the application (handler 1, for
example Wordle) answers through the application instead. An application without
an entry point uses `POST /activities/{channel}/{application}` with the session ID.
Leaving is `POST /applications/{application}/activities/{location}/instances/{instance}/leave`
with `{session_id}`. All three are single attempts.

## Outside voice channels

An Activity can run in a text channel or a DM without a call; its location is
that channel (`gc-GUILD-CHANNEL` or `pc-CHANNEL`). Its own slash command, such
as Wordle's `/wordle` (a chat input command), starts it: `POST /interactions`
with `analytics_location: "slash_ui"` and no `source`, then `INTERACTION_SUCCESS`
and an `EMBEDDED_ACTIVITY_UPDATE_V2` whose instance ID is the interaction's ID
and whose participant carries the interaction's `nonce`. No message is posted.
The official client docks the Activity above that channel's chat, keeps it
running when another channel is opened, and leaves it with the same leave
request. SakuraCord recognises its own launch by that nonce, so an instance
started by another client of the account is not taken over. OAuth from a guild
text channel sends `channel_type: 0` in the location context.

## Hosting

The official client loads `https://APPLICATION.discordsays.com/` in an iframe
(sandbox `allow-pointer-lock allow-scripts allow-same-origin allow-forms`,
`allow="autoplay; encrypted-media"`, referrer policy `origin`) with `instance_id`
(composite), `location_id`, `launch_id`, `guild_id`, `channel_id`, `frame_id`,
`platform=desktop`, `discord_shim=1`, display preferences and
`discord_proxy_ticket` from `POST /applications/{application}/proxy-tickets`
(`{use_stateless_ticket: true, channel_id}`; valid for five minutes). On load it
posts `[HELLO, parameters]` to the frame. SakuraCord does the same from a
discord.com-origin page that relays the SDK's `[opcode, payload]` frames between
the iframe and the host; the proxy's partitioned cookies work in WebKit's
third-party context. The page holds no Discord credential.

The handshake must name the launching application and frame; READY follows.
Commands answer with the same `cmd` and `nonce`; unsupported ones fail with
`INVALID_COMMAND` (4002) rather than staying unanswered, so Activities degrade.

Participation follows the voice session: when another client of the same account
takes over voice, Discord removes this session from the instance.

`AUTHORIZE` reads `GET /oauth2/authorize` (client ID, `response_type=code`,
scopes, state, `integration_type=1`). When it reports `authorized: true` no consent
is shown; otherwise the person approves first. One `POST` with
`{authorize: true, integration_type: 1, location_context}` follows; outside a
guild the context uses guild `10000` and channel type 1. Only the code from the
returned location reaches the Activity. `AUTHENTICATE` validates the Activity's
bearer token with `GET /oauth2/@me` and requires its application and this
account's user; that token's rejection never ends the account session.

A running instance is joined the same way from the channel. The official
client's Join button on a launch message instead sends
`POST /activities/{channel}/{application}` with `{session_id}`; both join the
existing instance.

## Messages and invites

Launching through the entry point can post the application's launch message:
type 23 with `interaction_metadata` (the launching user), the `application` and
`activity_instance: {id}` naming the composite instance. Its card shows the
Activity, who is playing from the instance updates, and Join while the instance
runs.

An Activity invite is a channel invite with `target_type: 2` and
`target_application_id`; the message carries only the invite link. The
official client renders it as its own card, at most 343 points wide: the
Activity's 16:9 `embedded_cover` (its preview video plays on hover), the
Activity's name, the icon beside "Activity Invite" and the voice channel and
server, the players' avatars with "N Playing" while an instance runs, and a
full-width Play or Join button, on a 45° gradient taken from the cover's
colour. Below 270 points the icon is dropped. The
Activity's invite dialog creates it with `POST /channels/{voice}/invites`, the
server invite body with those two fields and the context location
`Stream Invite`.
