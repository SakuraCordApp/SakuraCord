import Foundation

nonisolated extension SettingsCatalog {
    static let importExportPage = page(
        .importExport, group: .sakuraCord, title: "Import & Export", image: "arrow.up.arrow.down",
        help: "Save your local SakuraCord settings or restore them from a settings file.",
        keywords: ["backup", "restore", "transfer", "import", "export", "sakurasettings"]
    )
}

nonisolated extension SettingsControlID {
    static let memberListVisibility = Self(rawValue: "interface.member-list-visible")
    static let directMessageProfileVisibility = Self(rawValue: "interface.direct-message-profile-visible")
    static let groupDirectMessageMembersVisibility = Self(rawValue: "interface.group-direct-message-members-visible")

    static let inspectorVisibilityIDs: Set<Self> = [
        .memberListVisibility, .directMessageProfileVisibility, .groupDirectMessageMembersVisibility
    ]
}
