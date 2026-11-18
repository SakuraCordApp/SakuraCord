# Simulator media

Small, synthetic media files the simulator serves as attachments, embeds and
stickers. All were made for this project and have no third-party source or
attribution requirement. Everything else the simulator serves (avatars, icons,
banners, photos, custom emoji, generated stickers and GIFs) is drawn at request
time by `CDN/MediaGenerator.swift`; `MediaGenerator.bundled(_:)` reads the
files here.

| File | What it is | Used as |
| --- | --- | --- |
| `benchmark-video.mp4` | Two-second 320×180 H.264 colour clip, no audio | Video attachments and the video in link embeds |
| `demo-voice-message.ogg` | 6.2-second mono Ogg Opus clip of synthesized, speech-like tone bursts | Voice messages and audio-file attachments |
| `demo-sticker.apng` | Eight-frame 96×96 animated PNG pulse | The "Pip Pulse" APNG guild sticker |
| `benchmark-lottie.json` | Two-second 128×128 Lottie vector pulse | The standard "Wave" Lottie sticker |
| `demo-notes.txt` | A short band setlist in UTF-8 | The `setlist.txt` file attachment |
