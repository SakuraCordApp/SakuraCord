# Voice channel chat implementation

Observed and implemented on 21 July 2026.

## Behavior

- Selecting a voice channel shows the voice surface and opens its text chat in the supplementary conversation pane by default. It performs the normal first-page message load through the shared `ChatProvider` transport but does not join voice.
- Closing the chat gives the voice surface the full workspace. While it is closed, an **Open Chat** button replaces Search and Members in the voice-channel toolbar.
- Repeating **Open Chat** while the pane is already open performs no additional request.
- Closing the pane cancels an in-flight page load but does not disconnect from or join voice.
- Voice message history is readable only when the effective permissions include `VIEW_CHANNEL`, `READ_MESSAGE_HISTORY`, and `CONNECT`. Sending additionally requires `SEND_MESSAGES`.

The cold-cache request budget is one existing `GET /channels/{channel.id}/messages?limit=100` request when the voice channel is selected. Opening an already-open pane costs zero. Closing and reopening can refresh once while displaying any cached page immediately.

## Compatibility references

- Discord's public [Message Resource](https://docs.discord.com/developers/resources/message#get-channel-messages) documents Get Channel Messages for voice channels and the additional `CONNECT` permission requirement.
- Discord's public [Channel Resource](https://docs.discord.com/developers/resources/channel#channel-object-channel-types) identifies guild voice channels as channel type `2` and exposes ordinary channel message metadata such as `last_message_id`.
- The clean official Discord client observed on 21 July 2026 shows voice-channel text chat by default, replaces Search and Members with an **Open Chat** toolbar control while that chat is closed, and also exposes a row-level shortcut. SakuraCord deliberately keeps only the toolbar control to avoid redundant sidebar chrome. Opening chat does not implicitly join voice.
- Paicord revision `694761c1938b73bb60bd58942674dfe73aab1135` renders guild voice rows but disables selection, so it does not provide an equivalent voice-chat interaction.
- Swiftcord v1 revision `14465d927ebe1ba34b3befa00f9365fad7b56eb9` routes selected voice channels through its generic message loader, but does not separate voice selection, joining, and opening chat.

SakuraCord deliberately uses the official client's presentation and its existing bounded, rate-coordinated message transport. This change adds no new endpoint, headers, retry behavior, voice signaling, or unattended account action.
