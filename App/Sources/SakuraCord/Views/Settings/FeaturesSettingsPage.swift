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
                Toggle("Channel customization", isOn: value.channelManagement)
                    .tint(SakuraCordAccentColor.color)
                    .settingsControlAnchor(.channelManagement, state: state)
                Toggle("Show hidden channels", isOn: value.showHiddenChannels)
                    .tint(SakuraCordAccentColor.color)
                    .settingsControlAnchor(.showHiddenChannels, state: state)
            } header: {
                Text("Channels", bundle: #bundle)
            }
            FakeNitroSettingsSection(value: value, state: state)
            AttachmentSettingsSection(
                value: Binding(
                    get: { model.attachmentSettings },
                    set: { model.applyAttachmentSettings($0) }
                ),
                state: state
            )
        }
    }
}

private struct FakeNitroSettingsSection: View {
    @Binding var value: FeaturesSettingsSnapshot
    let state: SettingsViewState

    var body: some View {
        Section {
            Toggle("FakeNitro emojis", isOn: $value.fakeNitroEmojis)
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.fakeNitroEmojis, state: state)
            Toggle("FakeNitro stickers", isOn: $value.fakeNitroStickers)
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.fakeNitroStickers, state: state)
            Toggle("FakeNitro soundboard", isOn: $value.fakeNitroSoundboard)
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.fakeNitroSoundboard, state: state)
            Toggle("FakeNitro stream quality", isOn: $value.fakeNitroStreamQuality)
                .tint(SakuraCordAccentColor.color)
                .settingsControlAnchor(.fakeNitroStreamQuality, state: state)
        } header: {
            Text("FakeNitro", bundle: #bundle)
        }
    }
}
