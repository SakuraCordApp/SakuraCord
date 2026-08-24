import Foundation

nonisolated extension SettingsCatalog {
    static let aboutControls: [SettingsControlMetadata] = [
        aboutControl(
            .aboutVersionInformation, section: .aboutVersion,
            label: "Version Information",
            help: "Show SakuraCord’s semantic version.",
            keywords: ["app version", "version number"],
            owner: .appModel
        ),
        aboutControl(
            .aboutCheckForUpdates, section: .aboutVersion,
            label: "Check for Updates",
            help: "Invoke the existing Sparkle update action when this build supports it.",
            keywords: ["update now", "software update", "new version"], owner: .sparkle
        ),
        aboutControl(
            .aboutChangelog, section: .aboutVersion,
            label: "Open Changelog",
            help: "Show the release notes included with SakuraCord.",
            keywords: ["release notes", "what’s new", "versions"], owner: .appModel
        ),
        aboutControl(
            .aboutWebsite, section: .aboutLinks,
            label: "Website", help: "Open SakuraCord’s canonical website.",
            keywords: ["home", "sakuracord.app"], owner: .macOS
        ),
        aboutControl(
            .aboutRoadmap, section: .aboutLinks,
            label: "Roadmap", help: "Open SakuraCord’s deployed canonical roadmap.",
            keywords: ["planned", "progress", "roadmap service"], owner: .macOS
        ),
        aboutControl(
            .aboutSource, section: .aboutLinks,
            label: "Source", help: "Open SakuraCord’s public source repository.",
            keywords: ["GitHub", "code", "GPL"], owner: .macOS
        ),
        aboutControl(
            .aboutSupport, section: .aboutLinks,
            label: "Discord",
            help: "Open SakuraCord’s Discord support community invite.",
            keywords: ["help", "community", "Discord server"], owner: .macOS
        ),
        aboutControl(
            .aboutAcknowledgements, section: .aboutAcknowledgements,
            label: "Third-Party Acknowledgements",
            help: "Show the third-party notices included with SakuraCord.",
            keywords: ["licenses", "notices", "attribution"], owner: .appModel,
            persistence: .systemManaged
        ),
        aboutControl(
            .aboutDisclaimer, section: .aboutLegal,
            label: "Independence Disclaimer",
            help: "Explain SakuraCord’s independence from Discord and unsupported client compatibility risk.",
            keywords: ["not affiliated", "third party", "compatibility"],
            owner: .appModel
        ),
    ]

    private static func aboutControl(
        _ id: SettingsControlID,
        section: SettingsSectionID,
        label: String.LocalizationValue,
        help: String.LocalizationValue,
        keywords: [String.LocalizationValue],
        owner: SettingsValueOwner,
        persistence: SettingsPersistence = .notApplicable
    ) -> SettingsControlMetadata {
        SettingsControlMetadata(
            id: id,
            destination: SettingsDestination(page: .about, section: section),
            label: LocalizedStringResource(label, bundle: #bundle),
            help: LocalizedStringResource(help, bundle: #bundle),
            keywords: keywords.map { LocalizedStringResource($0, bundle: #bundle) },
            owner: owner,
            scope: .appWideLocal,
            persistence: persistence,
            resetCapability: .notApplicable,
            availability: .available
        )
    }
}
