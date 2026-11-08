# Voice, streams and soundboard

[Protocol index](../PROTOCOL_BASELINE.md)

## Owners and checks

Main-Gateway intent is built by
[DiscordGatewayPayloadFactory](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordGatewaySupport.swift);
[DiscordVoiceSession](../../Packages/MediaPipeline/Sources/MediaPipeline/DiscordVoiceSession.swift)
owns media negotiation/lifecycle. Stream state lives in
[DiscordApplicationStreams.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordApplicationStreams.swift);
[ScreenShareCaptureEngine](../../Packages/MediaPipeline/Sources/MediaPipeline/ScreenShareCaptureEngine.swift)
owns native capture. [DiscordRESTSoundboard.swift](../../Packages/DiscordProtocol/Sources/DiscordProtocol/DiscordRESTSoundboard.swift)
owns soundboard requests.

Representative verification:
[VoiceConnectionTests.swift](../../Packages/MediaPipeline/Tests/MediaPipelineTests/VoiceConnectionTests.swift),
[VoiceGatewayProtocolTests.swift](../../Packages/MediaPipeline/Tests/MediaPipelineTests/VoiceGatewayProtocolTests.swift),
[VoiceTransportTests.swift](../../Packages/MediaPipeline/Tests/MediaPipelineTests/VoiceTransportTests.swift) and
[SoundboardTests.swift](../../App/Tests/SakuraCordAppTests/SoundboardTests.swift).

## Control planes and recovery

The main Gateway owns channel membership, calls and stream discovery. A Voice
connection owns call media; each selected screen stream has a separate Voice
allocation. A stream stop must not leave the enclosing call. Match voice-server,
state and stream updates to the owning account/session before installing them.

Guild voice states from READY_SUPPLEMENTAL `merged_voice_states`, lazy guild
snapshots and `VOICE_STATE_UPDATE` are tracked for every guild. A guild
`VOICE_STATE_UPDATE` carries the participant's documented `member`; it is
admitted to the member cache only when that member is absent, without publishing
a member-list change. The server rail's hover card reads only cached members and
never sends a Gateway member request.

Negotiate transport, codecs and DAVE through MediaPipeline. UDP discovery and
provisional connection setup are bounded and clean up on failure; they cannot
leave an indefinite connecting state. Voice timeout `4009` identifies again.
Invalid/displaced or server-directed sessions (`4006`, `4014`, `4021`, `4022`)
tear down local media without publishing a main-Gateway leave that could disconnect
another client now owning the account's voice session. Other transient closures
use bounded resume. Device changes preserve the active session where possible.

## DAVE group identity and recovery

The MLS group ID is the voice channel ID, or the stream's RTC channel ID for
screen sharing. It is not the guild or RTC server ID. This matches production web
build `634304` (`web.843cc7edc28c426c.js`, checked 9 October 2026):
`trueChannelId` is passed to `prepareSecureFramesEpoch` and then `mlsSession.Init`.
Pinned Paicord and Swiftcord v1 have no DAVE implementation to corroborate.

Invalid commits or welcomes regenerate the MLS group and key package and discard
pending transitions, following the [DAVE recovery protocol](https://github.com/discord/dave-protocol/blob/main/protocol.md).
A fresh Voice Identify also discards the old participant allowlist and encryption
state; Resume retains them. Reinstalling the current epoch/user ratchet preserves
its sender nonce sequence and receiver replay window.

## Private calls

`CALL_CREATE`/`UPDATE`/`DELETE`, guildless voice states and `ongoing_rings` track
calls app-wide. Moving a user between calls first removes them from the old call.
A selected/joined private call subscribes with opcode 13 once per channel/session.
Joining sends main opcode 4 with nullable guild and the current mute/deafen/video
state, then negotiates Voice from pushed own-state/server events.

Starting a DM call first reads `/channels/{channel}/call`. Join voice, wait for
pushed call creation and ring once only when the readiness response is ringable.
A group-DM start skips that read. Joining an existing call sends no readiness
read or ring. An empty snapshot with no participants/rings is not an existing call.
Decline posts stop-ringing for the current recipient without joining.
Ring/stop-ringing mutations have one attempt; a later ring failure must not repeat
a successful media join. A null-channel opcode 4 leaves the call.

## Screen sharing

Stream keys identify guild/call, channel and owner. Main-Gateway create/watch/
delete/ping/pause operations are owned by the payload builders. Discovery and
server-allocation events update one stream store. A null endpoint waits for a
replacement; an unavailable stream retains explicit viewer/broadcaster intent,
pings the allocation and reconnects instead of treating it as a final stop.

A connected one-to-one DM initially auto-watches a discovered remote stream;
GDM and guild streams require explicit Watch. Stopping watching keeps the call
connected. Preview reads are lightweight and do not imply a broadcast upload.

Stream Voice Identify advertises a `screen` RID; the later media advertisement
uses `video`. Source quality uses semantic zero dimensions with `type:source`,
while the encoder retains actual capture dimensions; fixed quality advertises
its fixed dimensions. Viewer demand includes quality and rendered pixel counts;
hidden/unwatched streams request zero demand. Optional stream audio uses its
stream connection and Soundshare speaking flag, then plays through the existing
call output graph.

Capture begins only after explicit system-picker selection. Updating source or
quality reconfigures the owned stream; cancel/dismiss/stop/failure releases the
corresponding resources. Keep capture/encoding/delivery bounded. Skip capture
input before encoding under backpressure rather than discarding encoded reference
frames; loss/PLI requests a keyframe. Preserve audio source timing when old queued
frames are dropped. Exact pacing and buffer constants belong to the media code.

## Soundboard

Default sounds come from `/soundboard-default-sounds`; guild catalogues use main
Gateway opcode 31 with bounded deduplicated guild IDs. `SOUNDBOARD_SOUNDS` replaces
that guild's catalogue; create/update/delete dispatches reconcile it. Catalogue
failures are bounded and do not start REST fallback polling. Local preview is a
CDN read with no account mutation.

Native playback posts once to `/channels/{channel}/send-soundboard-sound`, with
sound/emoji fields and a source guild for custom sounds. Enforce current speaking,
soundboard and, where needed, external-sound permissions plus voice-state
restrictions. Self-mute does not block playback and must not be changed by it.
Defaults and same-guild sounds use native delivery. Cross-guild native delivery
requires the applicable entitlement; the app's configured fallback may mix the
sound into existing outgoing audio when allowed.

Local optimistic rendering suppresses its matching Gateway echo. Both supported
voice-effect event names feed the same consumer. CDN decode and outgoing mixing
never create another microphone graph or Voice connection. Self-muted microphone
samples remain zero before mixing. Deafen/output routing applies to local/incoming
playback; teardown and account replacement clear queued audio. Favourites/history
are covered by [synchronized settings](SETTINGS.md#emoji-gifs-stickers-and-sounds).
