import Foundation

@MainActor
final class SettingsTransferService {
    nonisolated static let pages: [SettingsPageID] = [
        .general, .features, .interface, .appearance, .notifications, .voiceVideo, .accessibility,
        .keyboardShortcuts, .privacySafety, .storageDownloads, .diagnostics, .softwareUpdates,
    ]

    private let preferences: SettingsPreferenceStore

    init(preferences: SettingsPreferenceStore = .shared) {
        self.preferences = preferences
    }

    func export(pages: Set<SettingsPageID>) -> SettingsArchive {
        var values: [String: SettingsPreferenceValue] = [:]
        for page in Self.pages where pages.contains(page) {
            values.merge(preferences.export(page: page)) { _, new in new }
        }
        return SettingsArchive(values: values)
    }

    /// Persist only registered local settings. Credentials and arbitrary UserDefaults keys are never accepted.
    func importPreferences(_ archive: SettingsArchive) -> SettingsImportReport {
        var report = SettingsImportReport()
        report.newerVersion = archive.version > SettingsArchive.currentVersion
        report.unsupportedKeys = archive.unsupportedKeys
        var values = archive.values
        if archive.version < 2,
           case let .string(raw) = values[SettingsControlID.messageAppearance.rawValue],
           MessageAppearance(rawValue: raw) != nil {
            // Old backups used this choice everywhere. Preserve any explicit context entries,
            // including unsupported values, rather than replacing them with the legacy choice.
            for id: SettingsControlID in [.directMessageAppearance, .groupMessageAppearance]
                where values[id.rawValue] == nil && !archive.unsupportedKeys.contains(id.rawValue) {
                values[id.rawValue] = .string(raw)
            }
        }
        var accepted: [String: SettingsPreferenceValue] = [:]
        for (key, value) in values.sorted(by: { $0.key < $1.key }) {
            let id = SettingsControlID(rawValue: key)
            guard let registration = preferences.registry.registration(id), registration.exports,
                  SettingsImportValidation.accepts(value, registration: registration)
            else {
                report.unsupportedKeys.append(key)
                continue
            }
            accepted[key] = value
        }
        removeConflictingShortcuts(from: &accepted, report: &report)
        for (key, value) in accepted {
            preferences.set(value, for: SettingsControlID(rawValue: key))
        }
        report.importedCount = accepted.count
        return report
    }

    private func removeConflictingShortcuts(from values: inout [String: SettingsPreferenceValue], report: inout SettingsImportReport) {
        let current = KeyboardShortcutSettingsStore(preferences: preferences).shortcuts
        // Validate the final map together, allowing swaps between imported shortcuts.
        // Removing a conflicting change can reveal another conflict with a restored assignment.
        var removed: Bool
        repeat {
            removed = false
            var candidate = current
            for action in KeyboardShortcutAction.allCases {
                if case let .string(raw) = values[action.controlID.rawValue] {
                    candidate[action] = KeyboardShortcutChord(storageValue: raw)
                }
            }
            for action in KeyboardShortcutAction.allCases {
                let key = action.controlID.rawValue
                guard values[key] != nil, let chord = candidate[action],
                      KeyboardShortcutPolicy.validate(chord, for: action, shortcuts: candidate) != .valid else { continue }
                values[key] = nil
                report.unsupportedKeys.append(key)
                removed = true
            }
        } while removed
    }

    func export(
        pages: Set<SettingsPageID>,
        updateController: AppUpdateController,
        launchAtLogin: LaunchAtLoginController
    ) async -> SettingsArchive {
        var archive = export(pages: pages)
        if pages.contains(.general) {
            await launchAtLogin.refresh()
            if launchAtLogin.isAvailable {
                archive.values[SettingsControlID.launchAtLogin.rawValue] = .bool(launchAtLogin.isEnabled)
            }
        }
        if pages.contains(.storageDownloads) {
            archive.values[SettingsControlID.downloadFolderBookmark.rawValue] = preferences.value(for: .downloadFolderBookmark)
        }
        if pages.contains(.softwareUpdates) {
            archive.values[SettingsControlID.updateReleaseTrack.rawValue] = .string(updateController.releaseTrack.rawValue)
            archive.values[SettingsControlID.updateAutomaticChecks.rawValue] = .bool(updateController.exportAutomaticPreference(for: .updateAutomaticChecks))
            archive.values[SettingsControlID.updateAutomaticDownloads.rawValue] = .bool(updateController.exportAutomaticPreference(for: .updateAutomaticDownloads))
        }
        return archive
    }

    func importArchive(
        _ archive: SettingsArchive,
        model: AppModel,
        updateController: AppUpdateController,
        launchAtLogin: LaunchAtLoginController
    ) async -> SettingsImportReport {
        var local = archive
        let managedIDs: [SettingsControlID] = [.launchAtLogin, .downloadFolderBookmark, .updateAutomaticChecks, .updateAutomaticDownloads]
        for id in managedIDs { local.values[id.rawValue] = nil }
        var report = importPreferences(local)
        let importedIDs = Set(local.values.keys).subtracting(report.unsupportedKeys)
        await model.reloadImportedSettings(importedIDs)
        if importedIDs.contains(SettingsControlID.updateReleaseTrack.rawValue),
           case let .string(raw) = local.values[SettingsControlID.updateReleaseTrack.rawValue],
           let track = AppUpdateReleaseTrack(rawValue: raw) {
            updateController.importReleaseTrack(track)
        }
        for id in [SettingsControlID.updateAutomaticChecks, .updateAutomaticDownloads] {
            guard let value = archive.values[id.rawValue] else { continue }
            guard case let .bool(enabled) = value else {
                report.unsupportedKeys.append(id.rawValue)
                continue
            }
            updateController.importAutomaticPreference(enabled, for: id)
            report.importedCount += 1
        }
        if let value = archive.values[SettingsControlID.launchAtLogin.rawValue] {
            if case let .bool(enabled) = value {
                await launchAtLogin.refresh()
                if launchAtLogin.isAvailable {
                    if enabled != launchAtLogin.isEnabled { await launchAtLogin.setEnabled(enabled) }
                    if let error = launchAtLogin.errorMessage {
                        report.notices.append("Open at login: \(error)")
                    } else if launchAtLogin.requiresApproval {
                        report.notices.append("Approve SakuraCord in System Settings → General → Login Items to open at login.")
                    } else {
                        report.importedCount += 1
                    }
                } else {
                    report.notices.append("Open at login is unavailable for this app installation.")
                }
            } else {
                report.unsupportedKeys.append(SettingsControlID.launchAtLogin.rawValue)
            }
        }
        restoreDownloadFolder(from: archive, report: &report)
        return report
    }

    private func restoreDownloadFolder(from archive: SettingsArchive, report: inout SettingsImportReport) {
        let id = SettingsControlID.downloadFolderBookmark
        guard let value = archive.values[id.rawValue] else { return }
        guard case let .string(encoded) = value else {
            report.unsupportedKeys.append(id.rawValue)
            return
        }
        let store = StorageDownloadsSettingsStore(preferences: preferences)
        if encoded.isEmpty {
            preferences.set(.string(""), for: id)
            preferences.set(.string(""), for: .downloadFolderName)
            report.importedCount += 1
            return
        }
        do {
            guard let data = Data(base64Encoded: encoded) else { throw SettingsArchiveError.invalidFile }
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting], bookmarkDataIsStale: &stale)
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let resource = try url.resourceValues(forKeys: [.isDirectoryKey, .isWritableKey])
            guard url.isFileURL, resource.isDirectory == true, resource.isWritable == true else { throw SettingsArchiveError.invalidFile }
            try store.saveDefaultFolder(url)
            report.importedCount += 1
        } catch {
            report.notices.append("The saved download folder is unavailable on this Mac. Choose a folder in Storage & Downloads; your current folder was preserved.")
        }
    }
}
