import Foundation
import Observation

nonisolated struct SettingsNavigationRequest: Equatable, Identifiable, Sendable {
    let id: UUID
    let destination: SettingsDestination
    let controlID: SettingsControlID
}

@Observable
final class SettingsNavigationRouter {
    static let shared = SettingsNavigationRouter()

    private(set) var request: SettingsNavigationRequest?

    private init() {}

    func open(
        page: SettingsPageID,
        section: SettingsSectionID? = nil,
        controlID: SettingsControlID? = nil
    ) {
        request = SettingsNavigationRequest(
            id: UUID(),
            destination: SettingsDestination(page: page, section: section),
            controlID: controlID ?? .overview(page)
        )
    }

    func consume(_ id: UUID) {
        guard request?.id == id else { return }
        request = nil
    }
}
