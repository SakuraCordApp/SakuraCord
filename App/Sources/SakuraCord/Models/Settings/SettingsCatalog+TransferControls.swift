import Foundation

nonisolated extension SettingsControlID {
    static let settingsExport = Self(rawValue: "import-export.export")
    static let settingsImport = Self(rawValue: "import-export.import")
    static let exportSelectAll = Self(rawValue: "import-export.select-all")
    static let exportDeselectAll = Self(rawValue: "import-export.deselect-all")

    static func exportCategory(_ page: SettingsPageID) -> Self {
        Self(rawValue: "import-export.include-\(page.deepLinkPath)")
    }
}

nonisolated extension SettingsSectionID {
    static let settingsTransfer = Self(rawValue: "import-export")
}

nonisolated extension SettingsCatalog {
    static let importExportPage = page(
        .importExport, group: .sakuraCord, title: "Import & Export", image: "arrow.up.arrow.down",
        help: "Save your local SakuraCord settings or restore them from a settings file.",
        keywords: ["backup", "restore", "transfer", "import", "export", "sakurasettings"]
    )

    static let transferControls: [SettingsControlMetadata] = [
        control(.settingsExport, page: .importExport, section: .settingsTransfer,
                label: "Export Settings", help: "Save selected local settings to a file.", keywords: [],
                owner: .applicationPreferences, scope: .appWideLocal, persistence: .sessionOnly, reset: .notApplicable),
        control(.settingsImport, page: .importExport, section: .settingsTransfer,
                label: "Import Settings", help: "Restore local settings from a file.", keywords: [],
                owner: .applicationPreferences, scope: .appWideLocal, persistence: .sessionOnly, reset: .notApplicable),
        control(.exportSelectAll, page: .importExport, section: .settingsTransfer,
                label: "Select All Export Categories", help: "Include every category in the export.", keywords: [],
                owner: .applicationPreferences, scope: .appWideLocal, persistence: .sessionOnly, reset: .notApplicable),
        control(.exportDeselectAll, page: .importExport, section: .settingsTransfer,
                label: "Deselect All Export Categories", help: "Clear the export category selection.", keywords: [],
                owner: .applicationPreferences, scope: .appWideLocal, persistence: .sessionOnly, reset: .notApplicable),
    ] + SettingsTransferService.pages.map { page in
        let metadata = foundationPages.first { $0.id == page }!
        return SettingsControlMetadata(
            id: .exportCategory(page), destination: .init(page: .importExport, section: .settingsTransfer),
            label: metadata.title, help: LocalizedStringResource("Include this category in exported settings.", bundle: #bundle),
            keywords: metadata.keywords, owner: .applicationPreferences, scope: .appWideLocal,
            persistence: .sessionOnly, resetCapability: .notApplicable, availability: .available
        )
    }
}
