import AppKit
import DiscordProtocol
import Foundation
import MediaPipeline
import SakuraCordModels

extension AppModel {
    func joinablePrivateCall(in channelID: ChannelID) -> PrivateCall? {
        guard let call = privateCall(in: channelID) else { return nil }
        if !call.ongoingRings.isEmpty {
            return call
        }
        guard let voiceStates = call.voiceStates else {
            // A partial CALL_UPDATE cannot prove that the call is empty.
            return call
        }
        return voiceStates.isEmpty ? nil : call
    }

    func joinVoice(_ channel: Channel) async {
        guard canJoinVoice(channel) else { return }
        if activeVoiceChannel?.id == channel.id,
           voiceSessionState == .connected || voiceSessionState == .connecting
        {
            return
        }
        let account = accountSession()
        guard await confirmIgnoredVoiceParticipants(in: channel), isCurrentAccountSession(account) else { return }
        voiceActionGeneration &+= 1
        let actionGeneration = voiceActionGeneration
        await leaveVoice(account: account, preservingVoiceActionGeneration: actionGeneration)
        guard isCurrentAccountSession(account),
              voiceActionGeneration == actionGeneration
        else { return }
        voiceMigrationGeneration &+= 1
        let voiceGeneration = voiceMigrationGeneration
        activeVoiceChannel = channel
        reconcilePrivateCallSounds()
        voiceSessionState = .connecting
        voiceErrorMessage = nil
        isVoiceMuted = voiceVideoPreferences.joinsMuted
        isVoiceDeafened = voiceVideoPreferences.joinsDeafened
        do {
            let info = try await account.provider.joinVoice(
                channelID: channel.id,
                guildID: channel.guildID,
                selfMute: isVoiceMuted,
                selfDeaf: isVoiceDeafened
            )
            guard isCurrentVoiceOperation(
                account,
                generation: voiceGeneration,
                channelID: channel.id
            ) else { return }
            try await startVoiceSession(
                with: info,
                account: account,
                generation: voiceGeneration
            )
            guard isCurrentVoiceOperation(
                account,
                generation: voiceGeneration,
                channelID: channel.id
            ) else { return }
            watchAvailableDirectMessageStreamsAutomatically()
            if voiceVideoPreferences.playsFeedbackSounds {
                soundPlayer.play(.userJoin)
            }
            if !voiceVideoPreferences.joinsWithCameraOff, !isCameraEnabled {
                await toggleCamera()
            }
        } catch {
            guard isCurrentVoiceOperation(
                account,
                generation: voiceGeneration,
                channelID: channel.id
            ) else { return }
            let failedSession = voiceSession
            voiceEventTask?.cancel()
            voiceEventTask = nil
            await failedSession?.disconnect()
            guard isCurrentVoiceOperation(
                account,
                generation: voiceGeneration,
                channelID: channel.id
            ) else { return }
            voiceSessionState = .failed
            DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
            voiceErrorMessage = error.localizedDescription
            errorMessage = error.localizedDescription
            try? await account.provider.updateVoiceState(
                channelID: nil,
                guildID: channel.guildID,
                selfMute: false,
                selfDeaf: false,
                selfVideo: false
            )
            guard isCurrentVoiceOperation(
                account,
                generation: voiceGeneration,
                channelID: channel.id
            ) else { return }
            activeVoiceChannel = nil
            if voiceSession === failedSession {
                voiceSession = nil
            }
            reconcilePrivateCallSounds()
        }
    }

    func startPrivateCall(in channel: Channel, withVideo: Bool = false) async {
        guard channel.isListedDirectMessage, !channel.isOfficialSystemDirectMessage else { return }

        await performPrivateCallAction(in: channel.id) { generation in
            await self.startPrivateCall(
                in: channel,
                withVideo: withVideo,
                generation: generation
            )
        }
    }

    func startPrivateCall(
        in channel: Channel,
        withVideo: Bool,
        generation: UInt64
    ) async {
        let session = accountSession()
        if joinablePrivateCall(in: channel.id) != nil {
            await joinPrivateCall(
                in: channel,
                withVideo: withVideo,
                generation: generation
            )
            return
        }

        do {
            try await session.provider.subscribeToPrivateCall(channelID: channel.id)
            guard isCurrentPrivateCallAction(
                channelID: channel.id,
                generation: generation
            ), isCurrentAccountSession(session) else { return }
            let shouldRing: Bool
            if channel.kind == .groupDirectMessage {
                shouldRing = true
            } else {
                shouldRing = try await session.provider.privateCallIsRingable(
                    channelID: channel.id
                )
            }
            guard isCurrentPrivateCallAction(
                channelID: channel.id,
                generation: generation
            ), isCurrentAccountSession(session) else { return }
            await completePrivateCallStart(
                in: channel,
                withVideo: withVideo,
                shouldRing: shouldRing,
                generation: generation
            )
        } catch {
            guard isCurrentAccountSession(session),
                  isCurrentPrivateCallAction(
                      channelID: channel.id,
                      generation: generation
                  )
            else { return }
            DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
            voiceErrorMessage = error.localizedDescription
            errorMessage = error.localizedDescription
        }
    }

    func completePrivateCallStart(
        in channel: Channel,
        withVideo: Bool,
        shouldRing: Bool,
        generation: UInt64
    ) async {
        let session = accountSession()
        await joinVoice(channel)
        guard isCurrentPrivateCallAction(
            channelID: channel.id,
            generation: generation
        ),
              activeVoiceChannel?.id == channel.id,
              voiceSessionState == .connected,
              isCurrentAccountSession(session)
        else { return }
        if withVideo, !isCameraEnabled {
            await toggleCamera()
            guard isCurrentPrivateCallAction(
                channelID: channel.id,
                generation: generation
            ), isCurrentAccountSession(session) else { return }
        }
        guard shouldRing else { return }
        beginLocalOutgoingPrivateCallRing(channelID: channel.id)
        do {
            try await session.provider.ringPrivateCall(
                channelID: channel.id,
                recipients: nil
            )
        } catch {
            guard isCurrentAccountSession(session),
                  isCurrentPrivateCallAction(
                      channelID: channel.id,
                      generation: generation
                  )
            else { return }
            endLocalOutgoingPrivateCallRing(channelID: channel.id)
            // Joining succeeded and is not replayed. Surface the bounded
            // ring failure without turning it into a second call action.
            DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
            voiceErrorMessage = error.localizedDescription
            errorMessage = error.localizedDescription
        }
    }

    func joinPrivateCall(in channel: Channel, withVideo: Bool = false) async {
        guard channel.isListedDirectMessage, !channel.isOfficialSystemDirectMessage else { return }

        await performPrivateCallAction(in: channel.id) { generation in
            await self.joinPrivateCall(
                in: channel,
                withVideo: withVideo,
                generation: generation
            )
        }
    }

    func joinPrivateCall(
        in channel: Channel,
        withVideo: Bool,
        generation: UInt64
    ) async {
        let session = accountSession()
        do {
            try await session.provider.subscribeToPrivateCall(channelID: channel.id)
            guard isCurrentPrivateCallAction(
                channelID: channel.id,
                generation: generation
            ), isCurrentAccountSession(session) else { return }
            await joinVoice(channel)
            if isCurrentPrivateCallAction(
                channelID: channel.id,
                generation: generation
            ),
               isCurrentAccountSession(session),
               withVideo,
               activeVoiceChannel?.id == channel.id,
               voiceSessionState == .connected,
               !isCameraEnabled
            {
                await toggleCamera()
            }
        } catch {
            guard isCurrentAccountSession(session),
                  isCurrentPrivateCallAction(
                      channelID: channel.id,
                      generation: generation
                  )
            else { return }
            DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
            voiceErrorMessage = error.localizedDescription
            errorMessage = error.localizedDescription
        }
    }

    func acceptPrivateCall(_ call: PrivateCall) async {
        guard let channel = knownRootChannel(call.channelID), channel.messageRequest == nil else { return }

        await performPrivateCallAction(in: call.channelID) { generation in
            if self.selectedChannelID != channel.id {
                self.selectedGuildID = nil
                self.selectedChannelID = channel.id
            }
            await self.joinPrivateCall(
                in: channel,
                withVideo: false,
                generation: generation
            )
        }
    }

    func declinePrivateCall(_ call: PrivateCall) async {
        guard let currentUserID = snapshot?.currentUser.id else { return }
        await performPrivateCallAction(in: call.channelID) { generation in
            await self.declinePrivateCall(
                call,
                currentUserID: currentUserID,
                generation: generation
            )
        }
    }

    func declinePrivateCall(
        _ call: PrivateCall,
        currentUserID: UserID,
        generation: UInt64
    ) async {
        let session = accountSession()
        do {
            try await session.provider.stopRingingPrivateCall(
                channelID: call.channelID,
                recipients: [currentUserID]
            )
            guard isCurrentPrivateCallAction(
                channelID: call.channelID,
                generation: generation
            ), isCurrentAccountSession(session) else { return }
            if var updated = privateCallsByChannel[call.channelID] {
                updated.ongoingRings.removeAll { $0.recipientID == currentUserID }
                privateCallsByChannel[call.channelID] = updated
                reconcilePrivateCallSounds()
            }
        } catch {
            guard isCurrentAccountSession(session),
                  isCurrentPrivateCallAction(
                      channelID: call.channelID,
                      generation: generation
                  )
            else { return }
            DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
            voiceErrorMessage = error.localizedDescription
            errorMessage = error.localizedDescription
        }
    }

    func performPrivateCallAction(
        in channelID: ChannelID,
        operation: (UInt64) async -> Void
    ) async {
        guard privateCallActionChannelIDs.insert(channelID).inserted else {
            return
        }
        let generation = privateCallActionGeneration
        defer {
            if generation == privateCallActionGeneration {
                privateCallActionChannelIDs.remove(channelID)
            }
        }
        await operation(generation)
    }

    func isCurrentPrivateCallAction(
        channelID: ChannelID,
        generation: UInt64
    ) -> Bool {
        generation == privateCallActionGeneration
            && privateCallActionChannelIDs.contains(channelID)
    }

    func resetPrivateCallActions() {
        privateCallActionGeneration &+= 1
        privateCallActionChannelIDs = []
    }

    func isCurrentVoiceOperation(
        _ account: AppModelAccountSession,
        generation: Int,
        channelID: ChannelID
    ) -> Bool {
        isCurrentAccountSession(account)
            && generation == voiceMigrationGeneration
            && activeVoiceChannel?.id == channelID
    }

    func isCurrentVoiceOperation(
        _ account: AppModelAccountSession,
        generation: Int,
        voiceSession expectedSession: DiscordVoiceSession?
    ) -> Bool {
        guard isCurrentAccountSession(account),
              generation == voiceMigrationGeneration
        else { return false }
        if let expectedSession {
            return voiceSession === expectedSession
        }
        return voiceSession == nil
    }

    func reconcilePrivateCallVoiceState(_ state: VoiceParticipantState) {
        for (channelID, var call) in privateCallsByChannel {
            var states = call.voiceStates ?? []
            let originalStates = states
            states.removeAll { $0.userID == state.userID }
            if channelID == state.channelID {
                states.append(state)
            }
            guard states != originalStates else { continue }
            call.voiceStates = states
            privateCallsByChannel[channelID] = call
        }
    }

    func beginLocalOutgoingPrivateCallRing(channelID: ChannelID) {
        locallyStartedOutgoingPrivateCallRings.insert(channelID)
        outgoingPrivateCallRingTimeoutTasks[channelID]?.cancel()
        outgoingPrivateCallRingTimeoutTasks[channelID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(45))
            } catch {
                return
            }
            self?.endLocalOutgoingPrivateCallRing(channelID: channelID)
        }
        reconcilePrivateCallSounds()
    }

    func endLocalOutgoingPrivateCallRing(channelID: ChannelID) {
        locallyStartedOutgoingPrivateCallRings.remove(channelID)
        outgoingPrivateCallRingTimeoutTasks.removeValue(forKey: channelID)?.cancel()
        reconcilePrivateCallSounds()
    }

    func reconcilePrivateCallSounds() {
        let state = PrivateCallSoundState.make(
            calls: privateCallsByChannel.values,
            currentUserID: snapshot?.currentUser.id,
            activeChannelID: activeVoiceChannel?.id,
            locallyStartedOutgoingChannelIDs:
                locallyStartedOutgoingPrivateCallRings
        )
        // Calls never post banners: the app rings and shows its own prompt
        // whether or not it is in front. Do Not Disturb and a muted
        // conversation silence it.
        let now = Date.now
        let ringingCalls = privateCallsByChannel.values.filter { call in
            snapshot.map { call.isRinging($0.currentUser.id) } == true && !isIncomingCallSuppressed(call)
        }
        scheduleRingingMuteExpiry(ringingCalls, now: now)
        let alertsIncoming = state.ringsIncoming
            && currentStatus != .dnd
            && ringingCalls.contains { call in
                privateCallMute(call, at: now) == nil
                    && notificationPreferences.allows(
                        .incomingCall,
                        isCurrentConversation: readState.isActivelyPresentedAtNewest(call.channelID)
                    )
            }
        soundPlayer.setLooping(.callRinging, active: alertsIncoming && notificationPreferences.playsSound)
        soundPlayer.setLooping(.callCalling, active: state.ringsOutgoing)
        // In the background the prompt is out of sight, so the Dock icon
        // bounces until SakuraCord comes forward or the ringing stops.
        requestIncomingCallAttention(alertsIncoming && !applicationIsActive)
    }

    /// The conversation's active mute, with its end if timed; nil when not
    /// muted. Read by ID: a ringing call can outlive its channel in the list.
    private func privateCallMute(_ call: PrivateCall, at date: Date) -> DiscordMuteConfiguration? {
        if snapshot?.channels.first(where: { $0.id == call.channelID })?.isMuted == true {
            return DiscordMuteConfiguration()
        }
        guard let override = readState.notificationOverride(channelID: call.channelID, guildID: nil),
              override.isMuted
        else { return nil }
        let mute = override.muteConfiguration ?? DiscordMuteConfiguration()
        return mute.isActive(at: date) ? mute : nil
    }

    /// A timed mute that ends while its call still rings lets it ring then.
    private func scheduleRingingMuteExpiry(_ calls: [PrivateCall], now: Date) {
        ringingMuteExpiryTask?.cancel()
        ringingMuteExpiryTask = nil
        guard let expiry = calls.compactMap({ privateCallMute($0, at: now)?.endTime }).min() else { return }
        ringingMuteExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.reconcilePrivateCallSounds()
        }
    }

    private func requestIncomingCallAttention(_ requested: Bool) {
        guard let application = NSApp else { return }
        if requested, incomingCallAttentionRequest == nil {
            incomingCallAttentionRequest = application.requestUserAttention(.criticalRequest)
        } else if !requested, let request = incomingCallAttentionRequest {
            application.cancelUserAttentionRequest(request)
            incomingCallAttentionRequest = nil
        }
    }

    func leaveVoice(
        account: AppModelAccountSession? = nil,
        expectedOperation: AppModelVoiceOperationIdentity? = nil,
        preservingVoiceActionGeneration preservedActionGeneration: UInt64? = nil,
        notifyDiscord: Bool = true
    ) async {
        let account = account ?? accountSession()
        guard isCurrentAccountSession(account) else { return }
        if let expectedOperation {
            guard isCurrentVoiceOperation(
                account,
                identity: expectedOperation
            ) else { return }
        }
        if let preservedActionGeneration {
            guard voiceActionGeneration == preservedActionGeneration else { return }
        } else {
            voiceActionGeneration &+= 1
        }
        let channel = activeVoiceChannel
        let guildID = channel?.guildID
        let hadActiveVoice = channel != nil
        let departingSession = voiceSession
        if let channelID = channel?.id {
            endLocalOutgoingPrivateCallRing(channelID: channelID)
        }
        voiceMigrationGeneration &+= 1
        let voiceGeneration = voiceMigrationGeneration
        voiceMigrationTask?.cancel()
        voiceMigrationTask = nil
        voiceEventTask?.cancel()
        voiceEventTask = nil
        await teardownApplicationStreams(account: account, notifyDiscord: notifyDiscord)
        await departingSession?.disconnect()
        guard isCurrentAccountSession(account),
              voiceMigrationGeneration == voiceGeneration,
              preservedActionGeneration.map({ voiceActionGeneration == $0 }) ?? true
        else { return }
        if voiceSession === departingSession {
            voiceSession = nil
        }
        if notifyDiscord, activeVoiceChannel?.id == channel?.id, channel != nil {
            try? await account.provider.updateVoiceState(
                channelID: nil,
                guildID: guildID,
                selfMute: false,
                selfDeaf: false,
                selfVideo: false
            )
        }
        guard isCurrentAccountSession(account),
              voiceMigrationGeneration == voiceGeneration,
              preservedActionGeneration.map({ voiceActionGeneration == $0 }) ?? true,
              activeVoiceChannel?.id == channel?.id
        else { return }
        activeVoiceChannel = nil
        voiceParticipants = []
        isLocallySpeaking = false
        voiceVideoFrames = [:]
        if notifyDiscord, let ownUserID = snapshot?.currentUser.id {
            voiceStates[ownUserID] = nil
        }
        voiceEncryptionVersion = nil
        voiceLatencyMilliseconds = nil
        voiceSessionState = .idle
        voiceConnectedAt = nil
        isCameraEnabled = false
        reconcilePrivateCallSounds()
        if hadActiveVoice, voiceVideoPreferences.playsFeedbackSounds {
            soundPlayer.play(.disconnect)
        }
    }

    func toggleVoiceMute() async {
        let account = accountSession()
        let generation = voiceMigrationGeneration
        let session = voiceSession
        isVoiceMuted.toggle()
        let muted = isVoiceMuted
        await session?.setMuted(muted)
        guard isCurrentVoiceOperation(
            account,
            generation: generation,
            voiceSession: session
        ) else { return }
        await publishVoiceState(account: account, generation: generation)
        guard isCurrentVoiceOperation(
            account,
            generation: generation,
            voiceSession: session
        ) else { return }
        if activeVoiceChannel != nil, voiceVideoPreferences.playsFeedbackSounds {
            soundPlayer.play(muted ? .mute : .unmute)
        }
    }

    func toggleVoiceDeafen() async {
        let account = accountSession()
        let generation = voiceMigrationGeneration
        let session = voiceSession
        isVoiceDeafened.toggle()
        let deafened = isVoiceDeafened
        await session?.setDeafened(deafened)
        guard isCurrentVoiceOperation(
            account,
            generation: generation,
            voiceSession: session
        ) else { return }
        await publishVoiceState(account: account, generation: generation)
        guard isCurrentVoiceOperation(
            account,
            generation: generation,
            voiceSession: session
        ) else { return }
        if activeVoiceChannel != nil, voiceVideoPreferences.playsFeedbackSounds {
            soundPlayer.play(deafened ? .deafen : .undeafen)
        }
    }

    func toggleCamera() async {
        let account = accountSession()
        let generation = voiceMigrationGeneration
        let session = voiceSession
        let enabled = !isCameraEnabled
        if session == nil {
            isCameraEnabled = enabled
            await publishVoiceState(account: account, generation: generation)
            guard isCurrentVoiceOperation(
                account,
                generation: generation,
                voiceSession: session
            ) else { return }
            if activeVoiceChannel != nil, voiceVideoPreferences.playsFeedbackSounds {
                soundPlayer.play(enabled ? .cameraOn : .cameraOff)
            }
            return
        }
        do {
            try await session?.setCameraEnabled(enabled)
            guard isCurrentVoiceOperation(
                account,
                generation: generation,
                voiceSession: session
            ) else { return }
            isCameraEnabled = enabled
            if !enabled, let ownUserID = snapshot?.currentUser.id {
                voiceVideoFrames[String(ownUserID.rawValue)] = nil
            }
            let channel = activeVoiceChannel
            try await account.provider.updateVoiceState(
                channelID: channel?.id,
                guildID: channel?.guildID,
                selfMute: isVoiceMuted,
                selfDeaf: isVoiceDeafened,
                selfVideo: enabled
            )
            guard isCurrentVoiceOperation(
                account,
                generation: generation,
                voiceSession: session
            ), activeVoiceChannel?.id == channel?.id else { return }
            if voiceVideoPreferences.playsFeedbackSounds {
                soundPlayer.play(enabled ? .cameraOn : .cameraOff)
            }
        } catch {
            guard isCurrentVoiceOperation(
                account,
                generation: generation,
                voiceSession: session
            ) else { return }
            DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
            voiceErrorMessage = error.localizedDescription
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func selectCamera(_ camera: CameraDeviceInfo?) async -> Bool {
        let account = accountSession()
        let generation = voiceMigrationGeneration
        let session = voiceSession
        do {
            try await session?.selectCamera(uniqueID: camera?.uniqueID)
            selectedCameraUID = camera?.uniqueID
            if voiceVideoPreferences.remembersCamera {
                voiceVideoPreferences.cameraUID = camera?.uniqueID ?? ""
            }
            voiceDeviceStatusMessage = camera.map {
                "Using “\($0.name)” as the camera."
            } ?? "Using the system-default camera."
            return true
        } catch {
            guard isCurrentVoiceOperation(
                account,
                generation: generation,
                voiceSession: session
            ) else { return false }
            voiceDeviceStatusMessage = "The camera could not be changed."
            DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
            voiceErrorMessage = error.localizedDescription
            errorMessage = error.localizedDescription
            return false
        }
    }

    func updateInputVolume(_ value: Float) async {
        inputVolume = min(max(value, 0), 2)
        await voiceSession?.setInputVolume(inputVolume)
    }

    func updateOutputVolume(_ value: Float) async {
        outputVolume = min(max(value, 0), 2)
        await voiceSession?.setOutputVolume(outputVolume)
    }

    func updateParticipantVolume(_ value: Float, userID: String) async {
        await voiceSession?.setParticipantVolume(value, userID: userID)
    }

    func publishVoiceState() async {
        await publishVoiceState(
            account: accountSession(),
            generation: voiceMigrationGeneration
        )
    }

    func publishVoiceState(
        account: AppModelAccountSession,
        generation: Int
    ) async {
        guard isCurrentAccountSession(account),
              generation == voiceMigrationGeneration,
              let activeVoiceChannel
        else { return }
        do {
            try await account.provider.updateVoiceState(
                channelID: activeVoiceChannel.id,
                guildID: activeVoiceChannel.guildID,
                selfMute: isVoiceMuted,
                selfDeaf: isVoiceDeafened,
                selfVideo: isCameraEnabled
            )
        } catch {
            guard isCurrentAccountSession(account),
                  generation == voiceMigrationGeneration
            else { return }
            DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
            voiceErrorMessage = error.localizedDescription
        }
    }

    func startVoiceSession(
        with info: VoiceConnectionInfo,
        account: AppModelAccountSession,
        generation: Int
    ) async throws {
        guard isCurrentVoiceOperation(
            account,
            generation: generation,
            channelID: info.channelID
        ) else { throw CancellationError() }
        if info.endpoint == "mock.sakuracord.invalid" {
            voiceSessionState = .connected
            return
        }

        let session = DiscordVoiceSession(
            info: info,
            configuration: currentVoiceConfiguration(),
            gatewayDiagnostics: voiceGatewayDiagnostics(transport: "voice_gateway")
        )
        voiceSession = session
        voiceEventTask?.cancel()
        voiceEventTask = Task { [weak self] in
            for await event in session.events {
                guard let self,
                      !Task.isCancelled,
                      self.isCurrentVoiceOperation(
                          account,
                          generation: generation,
                          voiceSession: session
                      )
                else { return }
                self.consumeVoiceEvent(event)
            }
        }
        do {
            try await session.connect()
        } catch {
            guard isCurrentVoiceOperation(
                account,
                generation: generation,
                voiceSession: session
            ) else { throw CancellationError() }
            throw error
        }
        guard isCurrentVoiceOperation(
            account,
            generation: generation,
            voiceSession: session
        ) else {
            await session.disconnect()
            throw CancellationError()
        }
    }

    func scheduleVoiceServerMigration(to info: VoiceConnectionInfo?) {
        recordVoiceServerMigrationScheduled(info)
        voiceMigrationGeneration &+= 1
        let generation = voiceMigrationGeneration
        voiceMigrationTask?.cancel()
        let account = accountSession()
        voiceMigrationTask = startAccountChildTask(account: account) { model, account in
            await model.migrateVoiceServer(
                to: info,
                generation: generation,
                account: account
            )
        }
    }

    func migrateVoiceServer(
        to info: VoiceConnectionInfo?,
        generation: Int,
        account: AppModelAccountSession
    ) async {
        guard !Task.isCancelled,
              isCurrentAccountSession(account),
              activeVoiceChannel != nil,
              generation == voiceMigrationGeneration
        else { return }
        let cameraWasEnabled = isCameraEnabled
        let previousSession = voiceSession

        voiceEventTask?.cancel()
        voiceEventTask = nil
        await previousSession?.disconnect()
        guard !Task.isCancelled,
              isCurrentAccountSession(account),
              generation == voiceMigrationGeneration
        else { return }

        if voiceSession === previousSession {
            voiceSession = nil
        }
        voiceParticipants = []
        voiceVideoFrames = [:]
        voiceEncryptionVersion = nil
        voiceLatencyMilliseconds = nil
        isCameraEnabled = false
        voiceSessionState = .reconnecting

        guard let info else { return recordVoiceServerMigrationWaiting() }
        guard info.channelID == activeVoiceChannel?.id else { return }

        do {
            recordVoiceServerMigrationStarted()
            try await startVoiceSession(
                with: info,
                account: account,
                generation: generation
            )
            guard !Task.isCancelled,
                  isCurrentAccountSession(account),
                  generation == voiceMigrationGeneration
            else {
                await voiceSession?.disconnect()
                return
            }
            if cameraWasEnabled, voiceSession != nil {
                let migratedSession = voiceSession
                try await migratedSession?.setCameraEnabled(true)
                guard isCurrentVoiceOperation(
                    account,
                    generation: generation,
                    voiceSession: migratedSession
                ) else { return }
                isCameraEnabled = true
            }
            recordVoiceServerMigrationCompleted()
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentAccountSession(account),
                  generation == voiceMigrationGeneration
            else { return }
            voiceSessionState = .failed
            DiscordAPIDiagnosticStore.shared.recordClientFailure(error)
            voiceErrorMessage = error.localizedDescription
            errorMessage = error.localizedDescription
            recordVoiceServerMigrationFailed(error)
        }
    }

    func consumeVoiceEvent(_ event: VoiceSessionEvent) {
        switch event {
        case .stateChanged(let state):
            recordVoiceSessionStateReceived(state)
            voiceSessionState = state
            if state == .connected {
                voiceConnectedAt = voiceConnectedAt ?? .now
                watchAvailableDirectMessageStreamsAutomatically()
            } else if state == .disconnected, activeVoiceChannel != nil {
                let account = accountSession()
                let operation = currentVoiceOperationIdentity()
                startAccountChildTask(account: account) { model, account in
                    await model.leaveVoice(
                        account: account,
                        expectedOperation: operation,
                        notifyDiscord: false
                    )
                }
            }
        case .latencyUpdated(let milliseconds):
            voiceLatencyMilliseconds = milliseconds
        case .participantChanged(let participant):
            if let index = voiceParticipants.firstIndex(where: { $0.userID == participant.userID }) {
                voiceParticipants[index] = participant
            } else {
                voiceParticipants.append(participant)
            }
            voiceParticipants.sort { $0.userID < $1.userID }
            if let userID = UserID(participant.userID), var state = voiceStates[userID] {
                state.isVideoEnabled = participant.isCameraEnabled
                voiceStates[userID] = state
            }
        case .participantLeft(let userID):
            voiceParticipants.removeAll { $0.userID == userID }
            voiceVideoFrames[userID] = nil
        case .localSpeakingChanged(let speaking):
            isLocallySpeaking = speaking
        case .encryptionReady(let version):
            voiceEncryptionVersion = version
        case .videoFrame(let userID, let frame):
            voiceVideoFrames[userID] = frame
        case .videoStopped(let userID):
            voiceVideoFrames[userID] = nil
        case .error(let message):
            voiceErrorMessage = message
        }
    }

    func consumeVoiceStateEvent(_ event: ClientEvent) {
        switch event {
        case .voiceStateChanged(let state):
            recordVoiceStateUpdateReceived(state)
            consumeVoiceStateChanged(state)
        case .voiceStatesReceived(let states):
            consumeInitialVoiceStates(states)
        default:
            break
        }
    }

    private func consumeInitialVoiceStates(_ states: [VoiceParticipantState]) {
        defersVoiceSidebarPresentation = true
        defer {
            defersVoiceSidebarPresentation = false
            refreshVoiceSidebarPresentation()
        }
        for state in states {
            consumeVoiceStateChanged(state)
        }
    }

    func consumeVoiceStateChanged(_ state: VoiceParticipantState) {
        let effects = VoiceStateSoundPolicy.effects(
            previous: voiceStates[state.userID],
            current: state,
            activeChannelID: activeVoiceChannel?.id,
            currentUserID: snapshot?.currentUser.id
        )
        voiceStates[state.userID] = state.channelID == nil ? nil : state
        stopOutgoingSoundboardAudioIfRestricted(by: state)
        reconcileApplicationStreamWatchSuppression(for: state)
        watchAvailableDirectMessageStreamsAutomatically()
        if !state.isVideoEnabled {
            voiceVideoFrames[String(state.userID.rawValue)] = nil
        }
        if state.guildID == nil {
            reconcilePrivateCallVoiceState(state)
        }
        if voiceVideoPreferences.playsFeedbackSounds {
            for effect in effects {
                soundPlayer.play(effect)
            }
        }
    }

    private func stopOutgoingSoundboardAudioIfRestricted(
        by state: VoiceParticipantState
    ) {
        guard state.userID == snapshot?.currentUser.id,
              state.channelID != activeVoiceChannel?.id
                || state.isMuted
                || state.isDeafened
                || state.isSelfDeafened
                || state.isSuppressed
        else { return }
        let session = voiceSession
        Task { await session?.stopOutgoingSoundboardAudio() }
    }
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

    func recordVoiceServerMigrationFailed(_ error: any Error) {
        DiscordAPIDiagnosticStore.shared.recordWebSocketLifecycle(
            transport: "voice_gateway", operation: "voice_server_migration_failed", error: error
        )
    }

    func recordVoiceSessionStateReceived(_ state: VoiceSessionState) {
        DiscordAPIDiagnosticStore.shared.recordWebSocketLifecycle(
            transport: "voice_gateway",
            operation: "app_session_state_\(state.rawValue)",
            flags: [
                "has_active_channel": activeVoiceChannel != nil,
                "has_session": voiceSession != nil,
            ],
            // The session owner records the originating failure before this projection.
            triggersPanicSave: false
        )
    }

    private func recordVoiceLifecycle(_ operation: String) {
        DiscordAPIDiagnosticStore.shared.recordWebSocketLifecycle(
            transport: "voice_gateway",
            operation: operation
        )
    }
}
