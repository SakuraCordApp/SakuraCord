import DiscordProtocol
import Foundation
import MediaPipeline
import SakuraCordModels

extension AppModel {
    func presentScreenSharePreview() async {
        guard activeVoiceChannel != nil, voiceSessionState == .connected else {
            screenShareErrorMessage = "Join a voice channel before sharing your screen."
            return
        }
        isScreenSharePreviewPresented = true
        screenShareErrorMessage = nil
        if let capture = screenShareCaptureEngine {
            capture.setPreviewEnabled(true)
            return
        }

        let capture = ScreenShareCaptureEngine(settings: screenShareSettings)
        screenShareCaptureEngine = capture
        isScreenShareCaptureAvailable = false
        screenShareCaptureState = .idle
        screenSharePreviewTask?.cancel()
        screenSharePreviewTask = Task { @MainActor [weak self, capture] in
            for await frame in capture.previewFrames {
                guard let self,
                      !Task.isCancelled,
                      self.screenShareCaptureEngine === capture
                else { return }
                self.screenSharePreviewFrame = frame
            }
        }
        screenShareCaptureEventTask?.cancel()
        screenShareCaptureEventTask = Task { @MainActor [weak self, capture] in
            for await event in capture.events {
                guard let self,
                      !Task.isCancelled,
                      self.screenShareCaptureEngine === capture
                else { return }
                self.consumeScreenShareCaptureEvent(event)
            }
        }
        do {
            try await capture.preparePreview()
        } catch {
            guard screenShareCaptureEngine === capture else { return }
            screenShareCaptureState = .failed(error.localizedDescription)
            screenShareErrorMessage = error.localizedDescription
            await capture.stop()
            if screenShareCaptureEngine === capture {
                screenShareCaptureEngine = nil
                isScreenShareCaptureAvailable = false
            }
        }
    }

    func dismissScreenSharePreview() async {
        isScreenSharePreviewPresented = false
        if localApplicationStreamKey != nil {
            screenShareCaptureEngine?.setPreviewEnabled(mainWindowIsActive)
            isLocalScreenSharePreviewPaused = !mainWindowIsActive
            return
        }
        screenShareCaptureEngine?.setPreviewEnabled(false)
        screenSharePreviewFrame = nil
        await releaseScreenShareCapture()
    }

    func changeScreenShareSource() async {
        if let screenShareCaptureEngine {
            await screenShareCaptureEngine.presentSourcePicker()
        } else {
            await presentScreenSharePreview()
            await screenShareCaptureEngine?.presentSourcePicker()
        }
    }

    func updateScreenShareSettings(_ settings: ScreenShareSettings) async {
        do {
            try await screenShareCaptureEngine?.updateSettings(settings)
        } catch {
            screenShareErrorMessage = error.localizedDescription
            return
        }
        screenShareSettings = settings
        do {
            try await localScreenShareSession?.updateScreenShareFormat()
            screenShareErrorMessage = nil
        } catch {
            screenShareErrorMessage = error.localizedDescription
        }
    }

    func startScreenSharing() async {
        guard !isStartingScreenShare,
              localApplicationStreamKey == nil,
              let channel = activeVoiceChannel,
              let capture = screenShareCaptureEngine,
              isScreenShareCaptureAvailable,
              voiceSessionState == .connected
        else { return }
        let account = accountSession()
        isStartingScreenShare = true
        screenShareErrorMessage = nil
        let expectedKey: ApplicationStreamKey? = if let userID = snapshot?.currentUser.id {
            ApplicationStreamKey(
                type: channel.guildID == nil ? .call : .guild,
                guildID: channel.guildID,
                channelID: channel.id,
                ownerID: userID
            )
        } else {
            nil
        }
        if let expectedKey {
            applicationStreamStates[expectedKey] = .connecting
        }
        do {
            let connection = try await account.provider.startApplicationStream(
                channelID: channel.id,
                guildID: channel.guildID,
                preferredRegion: privateCall(in: channel.id)?.region
            )
            guard isCurrentAccountSession(account),
                  activeVoiceChannel?.id == channel.id,
                  screenShareCaptureEngine === capture
            else {
                try? await account.provider.stopApplicationStream(connection.stream.key)
                throw CancellationError()
            }
            let key = connection.stream.key
            localApplicationStreamKey = key
            applicationStreams[key] = connection.stream
            applicationStreamStates[key] = .connecting
            try await connectApplicationStreamSession(
                connection,
                isBroadcaster: true,
                capture: capture,
                account: account
            )
            guard isCurrentAccountSession(account),
                  localApplicationStreamKey == key
            else {
                try? await account.provider.stopApplicationStream(key)
                await removeApplicationStreamSession(key, preservingCapture: false)
                if localApplicationStreamKey == key {
                    localApplicationStreamKey = nil
                }
                if screenShareCaptureEngine === capture {
                    await releaseScreenShareCapture()
                }
                throw CancellationError()
            }
            applicationStreamStates[key] = .broadcasting
            isScreenSharePreviewPresented = false
            isLocalScreenSharePreviewPaused = !mainWindowIsActive
            capture.setPreviewEnabled(mainWindowIsActive)
        } catch is CancellationError {
            if isCurrentAccountSession(account),
               activeVoiceChannel?.id == channel.id,
               screenShareCaptureEngine === capture,
               let expectedKey
            {
                applicationStreamStates[expectedKey] = nil
            }
        } catch {
            guard isCurrentAccountSession(account),
                  activeVoiceChannel?.id == channel.id,
                  screenShareCaptureEngine === capture
            else {
                isStartingScreenShare = false
                return
            }
            if let key = localApplicationStreamKey ?? expectedKey {
                applicationStreamStates[key] = .failed(error.localizedDescription)
                try? await account.provider.stopApplicationStream(key)
                await removeApplicationStreamSession(key, preservingCapture: false)
            }
            localApplicationStreamKey = nil
            screenShareCaptureState = .failed(error.localizedDescription)
            screenShareErrorMessage = error.localizedDescription
            await releaseScreenShareCapture()
        }
        isStartingScreenShare = false
    }

    func stopScreenSharing() async {
        guard let key = localApplicationStreamKey else {
            await dismissScreenSharePreview()
            return
        }
        let account = accountSession()
        bumpApplicationStreamGeneration(for: key)
        if let session = applicationStreamSessions[key] {
            await session.stopScreenShareCapture()
        }
        try? await account.provider.stopApplicationStream(key)
        await removeApplicationStreamSession(key, preservingCapture: false)
        applicationStreams[key] = nil
        applicationStreamStates[key] = nil
        applicationStreamFrames[key] = nil
        localApplicationStreamKey = nil
        isLocalScreenSharePreviewPaused = false
        isScreenSharePreviewPresented = false
        await releaseScreenShareCapture()
    }

    func watchApplicationStream(
        _ key: ApplicationStreamKey,
        automatically: Bool = false
    ) async {
        guard key != localApplicationStreamKey,
              activeVoiceChannel?.id == key.channelID,
              !automatically || !manuallyStoppedApplicationStreamKeys.contains(key),
              applicationStreamStates[key] != .connecting,
              applicationStreamStates[key] != .watching
        else { return }
        if !automatically {
            manuallyStoppedApplicationStreamKeys.remove(key)
        }
        let account = accountSession()
        let generation = bumpApplicationStreamGeneration(for: key)
        if applicationStreamDemandIntents[key] == nil {
            applicationStreamDemandIntents[key] = ApplicationStreamDemandIntent(
                isEnabled: true,
                pixelCount: nil
            )
        }
        applicationStreamStates[key] = .connecting
        do {
            let connection = try await account.provider.watchApplicationStream(key)
            guard isCurrentApplicationStreamOperation(
                key,
                generation: generation,
                account: account
            ) else {
                try? await account.provider.stopApplicationStream(key)
                throw CancellationError()
            }
            applicationStreams[key] = connection.stream
            try await connectApplicationStreamSession(
                connection,
                isBroadcaster: false,
                capture: nil,
                account: account
            )
            guard isCurrentApplicationStreamOperation(
                key,
                generation: generation,
                account: account
            ) else { throw CancellationError() }
            await applyApplicationStreamDemand(key)
            applicationStreamStates[key] = .watching
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentApplicationStreamOperation(
                key,
                generation: generation,
                account: account
            ) else { return }
            applicationStreamStates[key] = .failed(error.localizedDescription)
            applicationStreamFrames[key] = nil
            await removeApplicationStreamSession(key, preservingCapture: false)
            try? await account.provider.stopApplicationStream(key)
        }
    }

    func shouldAutomaticallyWatchApplicationStream(_ key: ApplicationStreamKey) -> Bool {
        guard let channel = activeVoiceChannel,
              channel.kind == .directMessage,
              voiceSessionState == .connected,
              key.type == .call,
              key.channelID == channel.id,
              let currentUserID = snapshot?.currentUser.id
        else { return false }
        return key.ownerID != currentUserID
            && !manuallyStoppedApplicationStreamKeys.contains(key)
    }

    func applicationStreamKeys(in channel: Channel) -> Set<ApplicationStreamKey> {
        var keys = Set(
            applicationStreams.keys.filter { $0.channelID == channel.id }
        )
        for state in voiceStates.values
        where state.channelID == channel.id && state.isStreaming {
            keys.insert(ApplicationStreamKey(
                type: channel.guildID == nil ? .call : .guild,
                guildID: channel.guildID,
                channelID: channel.id,
                ownerID: state.userID
            ))
        }
        if let localApplicationStreamKey,
           localApplicationStreamKey.channelID == channel.id
        {
            keys.insert(localApplicationStreamKey)
        }
        return keys
    }

    func watchAvailableDirectMessageStreamsAutomatically() {
        guard let channel = activeVoiceChannel else { return }
        let keys = applicationStreamKeys(in: channel)
        for key in keys
        where (applicationStreamStates[key] == nil
            || applicationStreamStates[key] == .available)
            && shouldAutomaticallyWatchApplicationStream(key) {
            Task { @MainActor [weak self] in
                await self?.watchApplicationStream(key, automatically: true)
            }
        }
    }

    func reconcileApplicationStreamWatchSuppression(for state: VoiceParticipantState) {
        guard !state.isStreaming else { return }
        manuallyStoppedApplicationStreamKeys = manuallyStoppedApplicationStreamKeys.filter {
            $0.ownerID != state.userID
                || (state.channelID != nil && $0.channelID != state.channelID)
        }
    }

    func stopWatchingApplicationStream(_ key: ApplicationStreamKey) async {
        guard key != localApplicationStreamKey else { return }
        manuallyStoppedApplicationStreamKeys.insert(key)
        let account = accountSession()
        bumpApplicationStreamGeneration(for: key)
        try? await account.provider.stopApplicationStream(key)
        await removeApplicationStreamSession(key, preservingCapture: false)
        applicationStreamDemandIntents[key] = nil
        applicationStreamFrames[key] = nil
        applicationStreamStates[key] = applicationStreams[key] == nil ? nil : .available
    }

    func setApplicationStreamDemand(
        _ enabled: Bool,
        key: ApplicationStreamKey,
        pixelCount: Int? = nil
    ) async {
        guard key != localApplicationStreamKey else { return }
        applicationStreamDemandIntents[key] = ApplicationStreamDemandIntent(
            isEnabled: enabled,
            pixelCount: enabled ? pixelCount : nil
        )
        let generation = (applicationStreamDemandGenerations[key] ?? 0) &+ 1
        applicationStreamDemandGenerations[key] = generation
        applicationStreamDemandUpdateTasks.removeValue(forKey: key)?.cancel()
        if enabled {
            applicationStreamDemandUpdateTasks[key] = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(120))
                } catch {
                    return
                }
                guard let self,
                      self.applicationStreamDemandGenerations[key] == generation,
                      self.applicationStreamDemandIntents[key]?.isEnabled == true
                else { return }
                self.applicationStreamDemandUpdateTasks[key] = nil
                await self.applyApplicationStreamDemand(key)
            }
            return
        }
        applicationStreamDemandUpdateTasks[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self,
                  self.applicationStreamDemandGenerations[key] == generation,
                  self.applicationStreamDemandIntents[key]?.isEnabled == false
            else { return }
            self.applicationStreamDemandUpdateTasks[key] = nil
            await self.applicationStreamSessions[key]?.setRemoteVideoDemand(false)
            self.applicationStreamFrames[key] = nil
        }
    }

    func consumeApplicationStreamChanged(_ stream: ApplicationStream) {
        applicationStreams[stream.key] = stream
        if applicationStreamStates[stream.key] == nil {
            applicationStreamStates[stream.key] = .available
        }
        watchAvailableDirectMessageStreamsAutomatically()
    }

    func consumeApplicationStreamDeleted(
        key: ApplicationStreamKey,
        unavailable: Bool,
        reason: String?
    ) {
        let wasLocal = key == localApplicationStreamKey
        let previousState = applicationStreamStates[key]
        let shouldReconnect = unavailable && (
            wasLocal
                || previousState == .watching
                || previousState == .connecting
                || previousState == .reconnecting
        )
        let generation = bumpApplicationStreamGeneration(for: key)
        let account = accountSession()
        applicationStreamEventTasks.removeValue(forKey: key)?.cancel()
        let departingSession = applicationStreamSessions.removeValue(forKey: key)
        if !unavailable {
            applicationStreams[key] = nil
            applicationStreamDemandIntents[key] = nil
            if reason != "user_requested" {
                manuallyStoppedApplicationStreamKeys.remove(key)
            }
        }
        applicationStreamFrames[key] = nil
        if shouldReconnect {
            applicationStreamStates[key] = .reconnecting
        } else {
            applicationStreamStates[key] = unavailable
                ? .failed(reason ?? "This screen share is temporarily unavailable.")
                : nil
        }
        if wasLocal, !unavailable {
            localApplicationStreamKey = nil
        }
        Task { [weak self] in
            guard let self else { return }
            await departingSession?.disconnect(
                preservingScreenCapture: shouldReconnect && wasLocal
            )
            if shouldReconnect {
                guard self.isCurrentApplicationStreamOperation(
                    key,
                    generation: generation,
                    account: account
                ) else { return }
                try? await account.provider.pingApplicationStream(key)
            } else if wasLocal {
                await self.releaseScreenShareCapture()
            }
        }
    }

    func consumeApplicationStreamServerChanged(
        key: ApplicationStreamKey,
        connection: ApplicationStreamConnectionInfo?
    ) {
        let hasReconnectIntent = applicationStreamSessions[key] != nil
            || applicationStreamStates[key] == .reconnecting
        guard hasReconnectIntent else { return }
        applicationStreamStates[key] = .reconnecting
        let account = accountSession()
        let generation = bumpApplicationStreamGeneration(for: key)
        Task { [weak self] in
            guard let self else { return }
            if let connection {
                await self.migrateApplicationStreamSession(
                    connection,
                    generation: generation,
                    account: account
                )
            } else {
                try? await account.provider.pingApplicationStream(key)
            }
        }
    }

    func handleApplicationStreamsForGatewayState(_ state: ConnectionState) {
        let retainedKeys = Set(applicationStreamSessions.keys).union(
            applicationStreamStates.compactMap { key, state in
                state == .reconnecting ? key : nil
            }
        )
        guard !retainedKeys.isEmpty else { return }
        if state == .ready {
            let account = accountSession()
            for key in retainedKeys {
                Task { try? await account.provider.pingApplicationStream(key) }
            }
        } else {
            for key in retainedKeys {
                applicationStreamStates[key] = .reconnecting
            }
        }
    }

    func teardownApplicationStreams(
        account: AppModelAccountSession,
        notifyDiscord: Bool
    ) async {
        let keys = Set(applicationStreamSessions.keys)
            .union(applicationStreams.keys)
            .union(localApplicationStreamKey.map { [$0] } ?? [])
        for key in keys {
            bumpApplicationStreamGeneration(for: key)
            await removeApplicationStreamSession(key, preservingCapture: false)
            if notifyDiscord {
                try? await account.provider.stopApplicationStream(key)
            }
        }
        applicationStreams = [:]
        applicationStreamStates = [:]
        applicationStreamFrames = [:]
        applicationStreamOperationGenerations = [:]
        applicationStreamDemandGenerations = [:]
        for task in applicationStreamDemandUpdateTasks.values { task.cancel() }
        applicationStreamDemandUpdateTasks = [:]
        applicationStreamDemandIntents = [:]
        manuallyStoppedApplicationStreamKeys = []
        localApplicationStreamKey = nil
        isScreenSharePreviewPresented = false
        await releaseScreenShareCapture()
    }

    private func connectApplicationStreamSession(
        _ connection: ApplicationStreamConnectionInfo,
        isBroadcaster: Bool,
        capture: ScreenShareCaptureEngine?,
        account: AppModelAccountSession
    ) async throws {
        let key = connection.stream.key
        if connection.voice.endpoint == "mock.sakuracord.invalid" {
            return
        }
        let voicePlaybackSession = voiceSession
        let remoteAudioHandler: (@Sendable (Data, String) async throws -> Void)? = if isBroadcaster {
            nil
        } else {
            { [voicePlaybackSession] opus, _ in
                try await voicePlaybackSession?.playRemoteAudio(
                    opus,
                    from: "application-stream:\(key.rawValue)"
                )
            }
        }
        let session = DiscordVoiceSession(
            info: connection.voice,
            kind: .applicationStream(isBroadcaster: isBroadcaster),
            configuration: currentVoiceConfiguration(),
            remoteAudioHandler: remoteAudioHandler,
            gatewayDiagnostics: VoiceGatewayDiagnostics { direction, data in
                DiscordAPIDiagnosticStore.shared.recordWebSocketData(
                    transport: "stream_voice_gateway",
                    direction: direction.rawValue,
                    data: data
                )
            }
        )
        applicationStreamSessions[key] = session
        applicationStreamEventTasks.removeValue(forKey: key)?.cancel()
        applicationStreamEventTasks[key] = Task { [weak self, session] in
            for await event in session.events {
                guard let self,
                      !Task.isCancelled,
                      self.isCurrentAccountSession(account),
                      self.applicationStreamSessions[key] === session
                else { return }
                self.consumeApplicationStreamSessionEvent(event, key: key)
            }
        }
        do {
            try await session.connect()
            if let capture {
                try await session.startScreenShareCapture(capture)
            }
        } catch {
            if applicationStreamSessions[key] === session {
                applicationStreamSessions[key] = nil
            }
            applicationStreamEventTasks.removeValue(forKey: key)?.cancel()
            await session.disconnect(preservingScreenCapture: capture != nil)
            throw error
        }
    }

    private func migrateApplicationStreamSession(
        _ connection: ApplicationStreamConnectionInfo,
        generation: UInt64,
        account: AppModelAccountSession
    ) async {
        let key = connection.stream.key
        guard isCurrentApplicationStreamOperation(
            key,
            generation: generation,
            account: account
        ) else { return }
        let isLocal = key == localApplicationStreamKey
        let capture = isLocal ? screenShareCaptureEngine : nil
        await removeApplicationStreamSession(key, preservingCapture: isLocal)
        do {
            try await connectApplicationStreamSession(
                connection,
                isBroadcaster: isLocal,
                capture: capture,
                account: account
            )
            guard isCurrentApplicationStreamOperation(
                key,
                generation: generation,
                account: account
            ) else { return }
            if !isLocal {
                if applicationStreamDemandIntents[key] == nil {
                    applicationStreamDemandIntents[key] = ApplicationStreamDemandIntent(
                        isEnabled: true,
                        pixelCount: nil
                    )
                }
                await applyApplicationStreamDemand(key)
            }
            applicationStreamStates[key] = isLocal ? .broadcasting : .watching
        } catch {
            guard isCurrentApplicationStreamOperation(
                key,
                generation: generation,
                account: account
            ) else { return }
            applicationStreamStates[key] = .failed(error.localizedDescription)
            screenShareErrorMessage = isLocal ? error.localizedDescription : nil
        }
    }

    func consumeApplicationStreamSessionEvent(
        _ event: VoiceSessionEvent,
        key: ApplicationStreamKey
    ) {
        switch event {
        case .stateChanged(let state):
            if state == .connected {
                applicationStreamStates[key] = key == localApplicationStreamKey
                    ? .broadcasting : .watching
            } else if state == .reconnecting {
                applicationStreamStates[key] = .reconnecting
                let account = accountSession()
                Task { try? await account.provider.pingApplicationStream(key) }
            } else if state == .failed {
                handleTerminalApplicationStreamSession(
                    key: key,
                    message: "The screen-share connection failed."
                )
            }
        case .videoFrame(_, let frame):
            applicationStreamFrames[key] = frame
        case .videoStopped:
            applicationStreamFrames[key] = nil
        case .error(let message):
            // VoiceSessionEvent.error reports recoverable packet, decoder, and
            // transport errors as well as terminal failures. The accompanying
            // `.stateChanged(.failed)` is the authoritative terminal signal;
            // changing playback state for every recoverable error made a live,
            // still-decoding share misleadingly display “Retry”.
            if key == localApplicationStreamKey {
                screenShareErrorMessage = message
            }
        case .latencyUpdated, .participantChanged, .participantLeft,
             .localSpeakingChanged, .encryptionReady:
            break
        }
    }

    func consumeApplicationStreamEvent(_ event: ClientEvent) -> Bool {
        switch event {
        case .applicationStreamChanged(let stream):
            consumeApplicationStreamChanged(stream)
        case .applicationStreamDeleted(let key, let unavailable, let reason):
            consumeApplicationStreamDeleted(
                key: key,
                unavailable: unavailable,
                reason: reason
            )
        case .applicationStreamServerChanged(let key, let connection):
            consumeApplicationStreamServerChanged(key: key, connection: connection)
        default:
            return false
        }
        return true
    }

    private func handleTerminalApplicationStreamSession(
        key: ApplicationStreamKey,
        message: String
    ) {
        let wasLocal = key == localApplicationStreamKey
        applicationStreamStates[key] = .reconnecting
        applicationStreamFrames[key] = nil
        Task { [weak self] in
            guard let self else { return }
            if wasLocal {
                await self.stopScreenSharing()
                guard self.activeVoiceChannel?.id == key.channelID else { return }
                self.isScreenSharePreviewPresented = true
                self.screenShareErrorMessage = message
                self.screenShareCaptureState = .failed(message)
            } else {
                await self.stopWatchingApplicationStream(key)
                guard self.applicationStreams[key] != nil,
                      self.activeVoiceChannel?.id == key.channelID
                else { return }
                self.applicationStreamStates[key] = .failed(message)
            }
        }
    }

    private func consumeScreenShareCaptureEvent(_ event: ScreenShareCaptureEvent) {
        switch event {
        case .stateChanged(let state):
            screenShareCaptureState = state
            switch state {
            case .failed(let message):
                screenShareErrorMessage = message
                handleTerminalScreenShareCapture(message: message)
            case .stopped:
                handleTerminalScreenShareCapture(
                    message: "Screen capture stopped. You can choose Share Screen to try again."
                )
            case .idle, .starting, .previewing, .sharing, .interrupted:
                break
            }
        case .sourceChanged(let name):
            screenShareSourceName = name
            isScreenShareCaptureAvailable = true
            screenShareErrorMessage = nil
            Task { [weak self] in
                try? await self?.localScreenShareSession?.updateScreenShareFormat()
            }
        case .pickerCancelled:
            if !isScreenShareCaptureAvailable {
                screenShareCaptureState = .idle
                screenShareErrorMessage = nil
            }
        case .error(let message):
            screenShareErrorMessage = message
            if !isScreenShareCaptureAvailable {
                screenShareCaptureState = .failed(message)
            }
        }
    }

    private func removeApplicationStreamSession(
        _ key: ApplicationStreamKey,
        preservingCapture: Bool
    ) async {
        applicationStreamDemandGenerations[key] = nil
        applicationStreamDemandUpdateTasks.removeValue(forKey: key)?.cancel()
        applicationStreamEventTasks.removeValue(forKey: key)?.cancel()
        let session = applicationStreamSessions.removeValue(forKey: key)
        await session?.disconnect(preservingScreenCapture: preservingCapture)
    }

    func updateApplicationStreamWindowActivity(_ isActive: Bool) {
        if localApplicationStreamKey != nil {
            isLocalScreenSharePreviewPaused = !isActive
        }
        screenShareCaptureEngine?.setPreviewEnabled(
            (isActive || isScreenSharePreviewPresented) && (
                isScreenSharePreviewPresented || localApplicationStreamKey != nil
            )
        )
        for key in Array(applicationStreamDemandIntents.keys) {
            Task { [weak self] in
                guard let self else { return }
                await self.applyApplicationStreamDemand(key)
            }
        }
    }

    private func applyApplicationStreamDemand(_ key: ApplicationStreamKey) async {
        guard let intent = applicationStreamDemandIntents[key] else { return }
        let isEnabled = mainWindowIsActive && intent.isEnabled
        await applicationStreamSessions[key]?.setRemoteVideoDemand(
            isEnabled,
            pixelCount: isEnabled ? intent.pixelCount : nil
        )
    }

    private func releaseScreenShareCapture() async {
        screenSharePreviewTask?.cancel()
        screenSharePreviewTask = nil
        screenShareCaptureEventTask?.cancel()
        screenShareCaptureEventTask = nil
        let capture = screenShareCaptureEngine
        screenShareCaptureEngine = nil
        isScreenShareCaptureAvailable = false
        await capture?.stop()
        screenSharePreviewFrame = nil
        isLocalScreenSharePreviewPaused = false
        screenShareSourceName = "Choose a source"
        if localApplicationStreamKey == nil {
            screenShareCaptureState = .idle
        }
    }

    private func handleTerminalScreenShareCapture(message: String) {
        guard isScreenShareCaptureAvailable else { return }
        isScreenShareCaptureAvailable = false
        let wasLive = localApplicationStreamKey != nil
        Task { [weak self] in
            guard let self else { return }
            if wasLive {
                await self.stopScreenSharing()
                self.isScreenSharePreviewPresented = true
            } else {
                await self.releaseScreenShareCapture()
            }
            self.screenShareErrorMessage = message
            self.screenShareCaptureState = .failed(message)
        }
    }

    @discardableResult
    private func bumpApplicationStreamGeneration(
        for key: ApplicationStreamKey
    ) -> UInt64 {
        let generation = (applicationStreamOperationGenerations[key] ?? 0) &+ 1
        applicationStreamOperationGenerations[key] = generation
        return generation
    }

    private func isCurrentApplicationStreamOperation(
        _ key: ApplicationStreamKey,
        generation: UInt64,
        account: AppModelAccountSession
    ) -> Bool {
        isCurrentAccountSession(account)
            && applicationStreamOperationGenerations[key] == generation
            && activeVoiceChannel?.id == key.channelID
    }

    private var localScreenShareSession: DiscordVoiceSession? {
        localApplicationStreamKey.flatMap { applicationStreamSessions[$0] }
    }
}
