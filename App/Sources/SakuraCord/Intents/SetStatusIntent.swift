import AppIntents
import Foundation
import SakuraCordModels

nonisolated enum IntentPresenceStatus: String, AppEnum {
    case online
    case idle
    case doNotDisturb
    case invisible

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Status")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .online: "Online",
        .idle: "Idle",
        .doNotDisturb: "Do Not Disturb",
        .invisible: "Invisible"
    ]

    var presence: PresenceStatus {
        switch self {
        case .online: .online
        case .idle: .idle
        case .doNotDisturb: .dnd
        case .invisible: .invisible
        }
    }

    var label: String {
        switch self {
        case .online: "Online"
        case .idle: "Idle"
        case .doNotDisturb: "Do Not Disturb"
        case .invisible: "Invisible"
        }
    }
}

struct SetStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Status"
    static let description = IntentDescription("Sets your SakuraCord status.")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Status")
    var status: IntentPresenceStatus

    init() {}

    init(status: IntentPresenceStatus) {
        self.status = status
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Set status to \(\.$status)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let label = status.label
        try await Self.apply(status.presence)
        return .result(dialog: "Status set to \(label).")
    }

    @MainActor
    private static func apply(_ presence: PresenceStatus) async throws {
        let model = try await IntentModelAccess.requireWorkspaceModel()
        let previousError = model.errorMessage
        await model.updateStatus(presence)
        // updateStatus reports failures through errorMessage, and the new status
        // arrives through the provider's status event, so confirm it landed.
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        while model.currentStatus != presence {
            guard model.errorMessage == previousError,
                  clock.now < deadline,
                  !Task.isCancelled
            else { throw IntentError.statusUpdateFailed }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
