# Offline media fixtures

`benchmark-video.mp4`, `benchmark-lottie.json`, and `demo-voice-message.ogg`
are small, synthetic media assets created for SakuraCord's offline timeline
fixtures. They have no third-party source or attribution requirement.

The MP4 is a two-second generated color clip with no audio. The Lottie file is
a simple generated vector pulse. The Ogg Opus clip is six seconds of
synthesized, speech-like tone bursts encoded by SakuraCord's own voice-message
recorder pipeline. All are intentionally small and
bundled by the `DiscordProtocol` Swift package so offline performance runs do
not contact remote media hosts.

`demo-sticker.apng` is an eight-frame synthetic pulse for the message showcase's
animated-PNG sticker. `demo-notes.txt` is its local file-attachment sample.
