import Foundation
import SakuraCordModels

extension MockMessageFixtureBuilder {
    func selectionFieldFixtureMessages() -> [Message] {
        [staticSelectionFieldFixture()]
            + dynamicSelectionFieldFixtures()
    }

    private func staticSelectionFieldFixture() -> Message {
        Message(
            id: MessageID(rawValue: 2012),
            channelID: ChannelID(rawValue: 210),
            author: verifiedApp,
            content:
                "**Selection field fixture — static options**\nChoose up to three areas to exercise searching, descriptions, emoji, defaults, and multi-select cards.",
            timestamp: base.addingTimeInterval(1_220),
            applicationID: fixtureApplicationID,
            guildID: auroraID,
            components: [
                .actionRow(
                    id: "fixture-static-select-row",
                    children: [
                        .select(
                            id: "fixture-static-select",
                            kind: .string,
                            customID: "offline-static-select",
                            placeholder: "Choose project areas…",
                            minValues: 1,
                            maxValues: 3,
                            disabled: false,
                            options: [
                                ComponentSelectOption(
                                    label: "Native macOS app",
                                    value: "macos",
                                    description: "AppKit and SwiftUI",
                                    imageURL: MockChatFixture.demoAsset(
                                        "guild-native-lab"
                                    ),
                                    imageShape: .roundedRectangle,
                                    isDefault: true
                                ),
                                ComponentSelectOption(
                                    label: "Web client",
                                    value: "web",
                                    description: "Browser experience",
                                    emoji: EmojiReference(name: "🌐")
                                ),
                                ComponentSelectOption(
                                    label: "Product design",
                                    value: "design",
                                    description: "Interaction and visual systems",
                                    emoji: EmojiReference(name: "🎨")
                                ),
                                ComponentSelectOption(
                                    label: "Performance",
                                    value: "performance",
                                    description: "Profiling and optimization",
                                    emoji: EmojiReference(name: "⚡️")
                                ),
                            ],
                            channelTypes: []
                        )
                    ]
                )
            ]
        )
    }

    private func dynamicSelectionFieldFixtures() -> [Message] {
        [
            dynamicSelectionFieldFixture(
                id: 2013,
                kind: .user,
                title: "Selection field fixture — dynamic choices",
                detail: "Search members such as <@1>, loaded asynchronously from the offline provider.",
                placeholder: "Choose up to six members…",
                minimum: 1,
                maximum: 6,
                accentColor: 0x5865F2
            ),
            dynamicSelectionFieldFixture(
                id: 2014,
                kind: .role,
                title: "Role select",
                detail: "Dynamic role choices, including a custom role image.",
                placeholder: "Choose roles…",
                maximum: 4,
                accentColor: 0x67E8F9
            ),
            dynamicSelectionFieldFixture(
                id: 2015,
                kind: .mentionable,
                title: "Mentionable select",
                detail: "Search members and roles in the same dynamic field.",
                placeholder: "Choose members or roles…",
                maximum: 6,
                accentColor: 0xF472B6
            ),
            dynamicSelectionFieldFixture(
                id: 2016,
                kind: .channel,
                title: "Channel select",
                detail: "Dynamic text and voice channel choices.",
                placeholder: "Choose channels…",
                maximum: 4,
                accentColor: 0xA7F3D0,
                channelTypes: [0, 2]
            ),
        ]
    }

    private func dynamicSelectionFieldFixture(
        id: UInt64,
        kind: ComponentSelectKind,
        title: String,
        detail: String,
        placeholder: String,
        minimum: Int = 0,
        maximum: Int,
        accentColor: UInt32,
        channelTypes: [Int] = []
    ) -> Message {
        let identifier = "fixture-\(kind.rawValue)-select"
        return Message(
            id: MessageID(rawValue: id),
            channelID: ChannelID(rawValue: 210),
            author: verifiedApp,
            content: "",
            timestamp: base.addingTimeInterval(
                1_280 + Double(id - 2013) * 60
            ),
            flags: [.isComponentsV2],
            applicationID: fixtureApplicationID,
            guildID: auroraID,
            components: [
                .container(
                    id: "\(identifier)-container",
                    accentColor: accentColor,
                    spoiler: false,
                    children: [
                        .textDisplay(
                            id: "\(identifier)-title",
                            content: "## \(title)\n\(detail)"
                        ),
                        .actionRow(
                            id: "\(identifier)-row",
                            children: [
                                .select(
                                    id: identifier,
                                    kind: kind,
                                    customID: "offline-\(kind.rawValue)-select",
                                    placeholder: placeholder,
                                    minValues: minimum,
                                    maxValues: maximum,
                                    disabled: false,
                                    options: [],
                                    channelTypes: channelTypes
                                )
                            ]
                        ),
                    ]
                )
            ],
            mentionedUsers: kind == .user ? [nova] : []
        )
    }

    private var fixtureApplicationID: ApplicationID {
        ApplicationID(rawValue: 900_000_000_000_000_101)
    }
}
