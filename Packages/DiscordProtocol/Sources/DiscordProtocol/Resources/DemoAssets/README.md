# Offline media fixtures

`benchmark-video.mp4` and `benchmark-lottie.json` are small, synthetic media
assets created for SakuraCord's offline timeline fixtures. They have no
third-party source or attribution requirement.

The MP4 is a two-second generated color clip with no audio. The Lottie file is
a simple generated vector pulse. Both files are intentionally small and
bundled by the `DiscordProtocol` Swift package so offline performance runs do
not contact remote media hosts.
