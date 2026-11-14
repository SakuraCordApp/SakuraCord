import SwiftUI

struct FeaturesSettingsPage: View {
    let model: AppModel
    let state: SettingsViewState

    var body: some View {
        let value = Binding(
            get: { model.featuresSettings },
            set: { model.applyFeaturesSettings($0) }
        )
        SettingsPageForm(page: .features, state: state) {
            Section {
                Toggle("Read All button", isOn: value.readAllButton)
                    .settingsControlAnchor(.readAllButton, state: state)
            } header: {
                Text("Notifications", bundle: #bundle)
            }
            Section {
                Toggle("Channel customization", isOn: value.channelManagement)
                    .settingsControlAnchor(.channelManagement, state: state)
                    .help("When off, all channels are shown and channel customization controls are hidden. Your server selections are preserved.")
                Toggle("Show hidden channels", isOn: value.showHiddenChannels)
                    .settingsControlAnchor(.showHiddenChannels, state: state)
                Toggle("Show Favorites server", isOn: Binding(
                    get: { model.favoritesAreEnabled },
                    set: { model.setFavoritesEnabled($0) }
                ))
                .disabled(model.favorites.settings == nil)
                .settingsControlAnchor(.showFavoritesServer, state: state)
                .help("Syncs with Discord. Your Favorites stay saved when this is off.")
            } header: {
                Text("Channels", bundle: #bundle)
            }
            FakeNitroSettingsSection(value: value, state: state)
            Section {
                Toggle("Message hover actions", isOn: value.messageHoverActions)
                    .settingsControlAnchor(.messageHoverActions, state: state)
                    .help("Show the floating reactions and actions menu when hovering a message.")
                Toggle("Scroll to bottom button", isOn: value.scrollToBottomButton)
                    .settingsControlAnchor(.scrollToBottomButton, state: state)
                    .help("Show the floating button above the composer that jumps to the latest message after scrolling up.")
            } header: {
                Text("Timeline", bundle: #bundle)
            }
            Section {
                Toggle("Record voice messages", isOn: value.voiceMessageRecording)
                    .settingsControlAnchor(.voiceMessageRecording, state: state)
                    .help("Show the composer’s record button. Voice messages in conversations play either way.")
            } header: {
                Text("Voice Messages", bundle: #bundle)
            }
            AttachmentSettingsSection(
                value: Binding(
                    get: { model.attachmentSettings },
                    set: { model.applyAttachmentSettings($0) }
                ),
                state: state
            )
            TranslationSettingsSection(model: model, state: state)
        }
    }
}

private struct FakeNitroSettingsSection: View {
    @Binding var value: FeaturesSettingsSnapshot
    let state: SettingsViewState

    var body: some View {
        Section {
            Toggle("FakeNitro emojis", isOn: $value.fakeNitroEmojis)
                .settingsControlAnchor(.fakeNitroEmojis, state: state)
            Toggle("FakeNitro stickers", isOn: $value.fakeNitroStickers)
                .settingsControlAnchor(.fakeNitroStickers, state: state)
            Toggle("FakeNitro soundboard", isOn: $value.fakeNitroSoundboard)
                .settingsControlAnchor(.fakeNitroSoundboard, state: state)
            Toggle("FakeNitro stream quality", isOn: $value.fakeNitroStreamQuality)
                .settingsControlAnchor(.fakeNitroStreamQuality, state: state)
            Toggle("Unlimited favorites", isOn: $value.unlimitedFavorites)
                .settingsControlAnchor(.unlimitedFavorites, state: state)
        } header: {
            Text("FakeNitro", bundle: #bundle)
        }
    }
}
