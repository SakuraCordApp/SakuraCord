import Foundation

nonisolated extension SettingsCatalog {
    static let aboutPage = page(
        .about, group: .sakuraCord, title: "About", image: "info.circle",
        help: "View SakuraCord version, project links, acknowledgements, and update availability.",
        keywords: ["version", "build", "website", "source", "roadmap", "acknowledgements"]
    )

    static let aboutControls: [SettingsControlMetadata] = [
        aboutControl(
            .aboutVersionInformation, section: .aboutVersion,
            label: "Version Information",
            help: "Show SakuraCord’s semantic version.",
            keywords: ["app version", "version number"]
        ),
        aboutControl(
            .aboutCheckForUpdates, section: .aboutVersion,
            label: "Check for Updates",
            help: "Invoke the existing Sparkle update action when this build supports it.",
            keywords: ["update now", "software update", "new version"]
        ),
        aboutControl(
            .aboutChangelog, section: .aboutVersion,
            label: "Open Changelog",
            help: "Show the release notes included with SakuraCord.",
            keywords: ["release notes", "what’s new", "versions"]
        ),
        aboutControl(
            .aboutWebsite, section: .aboutLinks,
            label: "Website", help: "Open SakuraCord’s canonical website.",
            keywords: ["home", "sakuracord.app"]
        ),
        aboutControl(
            .aboutRoadmap, section: .aboutLinks,
            label: "Roadmap", help: "Open SakuraCord’s deployed canonical roadmap.",
            keywords: ["planned", "progress", "roadmap service"]
        ),
        aboutControl(
            .aboutSource, section: .aboutLinks,
            label: "Source", help: "Open SakuraCord’s public source repository.",
            keywords: ["GitHub", "code", "GPL"]
        ),
        aboutControl(
            .aboutSupport, section: .aboutLinks,
            label: "Discord",
            help: "Open SakuraCord’s Discord support community invite.",
            keywords: ["help", "community", "Discord server"]
        ),
        aboutControl(
            .aboutSponsor, section: .aboutLinks,
            label: "Sponsor", help: "Open SakuraCord’s GitHub Sponsors page.",
            keywords: ["GitHub Sponsors", "donate", "funding"]
        ),
        aboutControl(
            .aboutAcknowledgements, section: .aboutAcknowledgements,
            label: "Third-Party Acknowledgements",
            help: "Show the third-party notices included with SakuraCord.",
            keywords: ["licenses", "notices", "attribution"]
        ),
        aboutControl(
            .aboutDisclaimer, section: .aboutLegal,
            label: "Independence Disclaimer",
            help: "Explain SakuraCord’s independence from Discord and unsupported client compatibility risk.",
            keywords: ["not affiliated", "third party", "compatibility"]
        ),
    ]

    private static func aboutControl(
        _ id: SettingsControlID,
        section: SettingsSectionID,
        label: String.LocalizationValue,
        help: String.LocalizationValue,
        keywords: [String.LocalizationValue]
    ) -> SettingsControlMetadata {
        control(
            id,
            page: .about,
            section: section,
            label: label,
            help: help,
            keywords: keywords
        )
    }
}
