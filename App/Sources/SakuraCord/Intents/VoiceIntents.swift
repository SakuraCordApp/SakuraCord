import AppIntents
import Foundation

nonisolated struct ToggleVoiceMuteIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Mute"
    static let description = IntentDescription("Toggles your microphone mute in the current SakuraCord voice channel.")
    static let openAppWhenRun: Bool = true

    static var parameterSummary: some ParameterSummary {
        Summary("Toggle microphone mute")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let muted = try await Self.toggle()
        return .result(dialog: muted ? "Microphone muted." : "Microphone unmuted.")
    }

    @MainActor
    private static func toggle() async throws -> Bool {
        let model = try await IntentModelAccess.requireVoiceModel()
        await model.toggleVoiceMute()
        // Report what the model published after the toggle; the call may have
        // left voice or been superseded while it was suspended.
        guard model.activeVoiceChannel != nil else {
            throw IntentError.notInVoice
        }
        return model.isVoiceMuted
    }
}

nonisolated struct ToggleVoiceDeafenIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Deafen"
    static let description = IntentDescription("Toggles deafen in the current SakuraCord voice channel.")
    static let openAppWhenRun: Bool = true

    static var parameterSummary: some ParameterSummary {
        Summary("Toggle deafen")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let deafened = try await Self.toggle()
        return .result(dialog: deafened ? "Deafened." : "Undeafened.")
    }

    @MainActor
    private static func toggle() async throws -> Bool {
        let model = try await IntentModelAccess.requireVoiceModel()
        await model.toggleVoiceDeafen()
        // Report what the model published after the toggle; the call may have
        // left voice or been superseded while it was suspended.
        guard model.activeVoiceChannel != nil else {
            throw IntentError.notInVoice
        }
        return model.isVoiceDeafened
    }
}
