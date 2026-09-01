import DiscordProtocol
import MediaPipeline
import SakuraCordModels

extension AppModel {
    func recordVoiceStateUpdateReceived(_ state: VoiceParticipantState) {
        let isCurrentUser = state.userID == snapshot?.currentUser.id
        guard isCurrentUser || state.channelID == activeVoiceChannel?.id else { return }
        let previousState = voiceStates[state.userID]
        DiscordAPIDiagnosticStore.shared.recordWebSocketLifecycle(
            transport: "gateway",
            operation: "voice_state_update_received",
            flags: [
                "current_user": isCurrentUser,
                "has_channel": state.channelID != nil,
                "has_guild": state.guildID != nil,
                "matches_active_channel": state.channelID != nil
                    && activeVoiceChannel != nil
                    && state.channelID == activeVoiceChannel?.id,
                "replaced_session": previousState != nil
                    && previousState?.sessionID != state.sessionID,
                "self_deafened": state.isSelfDeafened,
                "self_muted": state.isSelfMuted,
                "streaming": state.isStreaming,
                "video_enabled": state.isVideoEnabled,
            ]
        )
    }

    func recordVoiceServerUpdateReceived(_ info: VoiceConnectionInfo?) {
        let ownVoiceState = snapshot.flatMap { voiceStates[$0.currentUser.id] }
        DiscordAPIDiagnosticStore.shared.recordWebSocketLifecycle(
            transport: "gateway",
            operation: "voice_server_update_received",
            flags: [
                "connection_available": info != nil,
                "has_active_channel": activeVoiceChannel != nil,
                "matches_active_channel": info != nil
                    && activeVoiceChannel != nil
                    && info?.channelID == activeVoiceChannel?.id,
                "matches_current_session": info != nil
                    && ownVoiceState != nil
                    && info?.sessionID == ownVoiceState?.sessionID,
            ]
        )
    }

    func recordVoiceServerMigrationScheduled(_ info: VoiceConnectionInfo?) {
        DiscordAPIDiagnosticStore.shared.recordWebSocketLifecycle(
            transport: "voice_gateway",
            operation: "voice_server_migration_scheduled",
            flags: [
                "connection_available": info != nil,
                "has_active_channel": activeVoiceChannel != nil,
                "matches_active_channel": info != nil
                    && activeVoiceChannel != nil
                    && info?.channelID == activeVoiceChannel?.id,
            ]
        )
    }

    func recordVoiceServerMigrationWaiting() {
        recordVoiceLifecycle("voice_server_migration_waiting")
    }

    func recordVoiceServerMigrationStarted() {
        recordVoiceLifecycle("voice_server_migration_started")
    }

    func recordVoiceServerMigrationCompleted() {
        recordVoiceLifecycle("voice_server_migration_completed")
    }

    func recordVoiceServerMigrationFailed() {
        recordVoiceLifecycle("voice_server_migration_failed")
    }

    func recordVoiceSessionStateReceived(_ state: VoiceSessionState) {
        DiscordAPIDiagnosticStore.shared.recordWebSocketLifecycle(
            transport: "voice_gateway",
            operation: "app_session_state_\(state.rawValue)",
            flags: [
                "has_active_channel": activeVoiceChannel != nil,
                "has_session": voiceSession != nil,
            ]
        )
    }

    private func recordVoiceLifecycle(_ operation: String) {
        DiscordAPIDiagnosticStore.shared.recordWebSocketLifecycle(
            transport: "voice_gateway",
            operation: operation
        )
    }
}
