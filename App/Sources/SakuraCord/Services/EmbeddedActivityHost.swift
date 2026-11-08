import AppKit
import DiscordProtocol
import SakuraCordModels
import WebKit

/// Hosts one Activity as the parent side of Discord's Embedded App SDK.
///
/// Like Discord's client, a discord.com-origin page frames the Activity and
/// relays the SDK's `postMessage` frames between that iframe and this host.
/// The page holds no Discord credential; only replies the host builds reach it.
@MainActor
final class EmbeddedActivityHost: NSObject {
    private enum Opcode: Int {
        case handshake = 0, frame, close, hello
    }

    private enum RPCError: Int {
        case invalidPayload = 4000, invalidCommand = 4002, invalidEvent = 4004, invalidChannel = 4005
        case invalidPermissions = 4006, invalidToken = 4009, oauth2 = 5000
    }

    private static let handlerName = "sakuracordActivity"
    private static let supportedEvents: Set<String> = [
        "ACTIVITY_INSTANCE_PARTICIPANTS_UPDATE", "VOICE_STATE_UPDATE", "SPEAKING_START", "SPEAKING_STOP",
        "ACTIVITY_LAYOUT_MODE_UPDATE", "ORIENTATION_UPDATE", "CURRENT_USER_UPDATE", "CURRENT_GUILD_MEMBER_UPDATE",
        "THERMAL_STATE_UPDATE", "ENTITLEMENT_CREATE", "RELATIONSHIP_UPDATE",
    ]

    let webView: WKWebView
    private weak var model: AppModel?
    private let application: EmbeddedActivityApplication
    private let instance: EmbeddedActivityInstance
    /// The launch this host belongs to; its questions end with that launch.
    private let launchID: UUID
    private let frameID = UUID().uuidString.lowercased()
    private var subscriptions: Set<String> = []
    private var speakingUserIDs: Set<String> = []
    private var voiceStates: [UserID: VoiceParticipantState] = [:]
    private var isStopped = false

    init(
        model: AppModel, instance: EmbeddedActivityInstance, application: EmbeddedActivityApplication, launchID: UUID,
        proxyTicket: String
    ) {
        self.model = model
        self.launchID = launchID
        self.application = application
        self.instance = instance
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // Some Activities only enable features for browsers they recognise.
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        configuration.preferences.isElementFullscreenEnabled = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(WeakMessageHandler(self), contentWorld: .page, name: Self.handlerName)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.underPageBackgroundColor = .black
        #if DEBUG
            webView.isInspectable = true
        #endif
        voiceStates = currentVoiceStates()
        observeVoice()
        webView.loadHTMLString(hostPage(proxyTicket: proxyTicket), baseURL: Self.hostURL)
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: .page)
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    private static let hostURL = URL(string: "https://discord.com/activities")!

    /// The Activity iframe with the official client's sandbox, permissions and
    /// launch parameters, and the relay between it and this host.
    private func hostPage(proxyTicket: String) -> String {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        var parameters = [
            "theme": isDark ? "dark" : "light",
            "frame_id": frameID,
            "platform": "desktop",
            "discord_shim": "1",
        ]
        if application.isContextless {
            // The official client's parameters for an Activity on the main surface.
            parameters["instance_id"] = "example-cl-instance"
            parameters["surface"] = "0"
        } else {
            parameters["instance_id"] = instance.compositeInstanceID
            parameters["location_id"] = instance.location.id
            parameters["launch_id"] = instance.instanceID
            parameters["channel_id"] = instance.location.channelID.description
            parameters["guild_id"] = instance.location.guildID?.description
        }
        var components = URLComponents(url: application.activityURL, resolvingAgainstBaseURL: false)!
        components.queryItems = parameters.sorted { $0.key < $1.key }.map(URLQueryItem.init)
            + [URLQueryItem(name: "discord_proxy_ticket", value: proxyTicket)]
        let literals = (try? JSONSerialization.data(withJSONObject: [
            "source": components.url!.absoluteString,
            "origin": "https://\(application.activityURL.host() ?? "")",
            "hello": parameters,
        ])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;height:100%;overflow:hidden;background:#000}iframe{display:block;border:0;width:100%;height:100%}</style>
        </head><body><iframe id="activity" allow="autoplay; encrypted-media; fullscreen" referrerpolicy="origin"
        sandbox="allow-pointer-lock allow-scripts allow-same-origin allow-forms allow-popups allow-popups-to-escape-sandbox"></iframe>
        <script>
        const config = \(literals);
        const frame = document.getElementById('activity');
        const handler = window.webkit.messageHandlers.\(Self.handlerName);
        window.addEventListener('message', event => {
            if (event.source !== frame.contentWindow || event.origin !== config.origin) return;
            try { handler.postMessage(JSON.parse(JSON.stringify(event.data))); } catch (error) {}
        });
        window.deliver = message => frame.contentWindow.postMessage(message, config.origin);
        frame.addEventListener('load', () => window.deliver([3, config.hello]));
        frame.src = config.source;
        </script></body></html>
        """
    }

    // MARK: Transport

    fileprivate func receive(_ message: WKScriptMessage) {
        guard !isStopped, message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.host == Self.hostURL.host(),
              let tuple = message.body as? [Any], tuple.count >= 2,
              let opcode = (tuple[0] as? NSNumber).flatMap({ Opcode(rawValue: $0.intValue) }),
              let payload = tuple[1] as? [String: Any]
        else { return }
        switch opcode {
        case .handshake:
            guard payload["client_id"] as? String == application.id.description,
                  payload["frame_id"] as? String == frameID
            else {
                send(.close, ["code": 4000, "message": "Invalid client ID"])
                return
            }
            dispatch("READY", [
                "v": 1,
                "config": ["cdn_host": "cdn.discordapp.com", "api_endpoint": "//discord.com/api", "environment": "production"],
                "user": currentUserPayload(includesFlags: false),
            ])
        case .frame:
            guard let command = payload["cmd"] as? String, let nonce = payload["nonce"] as? String else { return }
            Task { await handle(command, nonce: nonce, event: payload["evt"] as? String, args: payload["args"] as? [String: Any] ?? [:]) }
        case .close, .hello:
            break
        }
    }

    private func send(_ opcode: Opcode, _ payload: [String: Any]) {
        guard !isStopped else { return }
        webView.callAsyncJavaScript(
            "window.deliver([opcode, payload]);",
            arguments: ["opcode": opcode.rawValue, "payload": payload], in: nil, in: .page
        )
    }

    private func reply(_ command: String, _ nonce: String, _ data: Any?) {
        send(.frame, ["cmd": command, "nonce": nonce, "evt": NSNull(), "data": data ?? NSNull()])
    }

    private func fail(_ command: String, _ nonce: String, _ error: RPCError, _ message: String) {
        send(.frame, ["cmd": command, "nonce": nonce, "evt": "ERROR", "data": ["code": error.rawValue, "message": message]])
    }

    private func dispatch(_ event: String, _ data: Any) {
        send(.frame, ["cmd": "DISPATCH", "evt": event, "nonce": NSNull(), "data": data])
    }

    // MARK: Commands

    // swiftlint:disable:next cyclomatic_complexity
    private func handle(_ command: String, nonce: String, event: String?, args: [String: Any]) async {
        guard let model else { return }
        switch command {
        case "AUTHORIZE":
            await authorize(nonce: nonce, args: args, model: model)
        case "AUTHENTICATE":
            guard let token = args["access_token"] as? String, !token.isEmpty else {
                return fail(command, nonce, .invalidToken, "Invalid access token")
            }
            do {
                let authorization = try await model.accountSession().provider.authenticateEmbeddedActivity(
                    application.id, accessToken: token
                )
                reply(command, nonce, Self.foundationValue(authorization))
            } catch {
                fail(command, nonce, .invalidToken, "Invalid access token")
            }
        case "SUBSCRIBE", "UNSUBSCRIBE":
            guard let event, Self.supportedEvents.contains(event) else {
                return fail(command, nonce, .invalidEvent, "Unsupported event")
            }
            if command == "SUBSCRIBE" { subscriptions.insert(event) } else { subscriptions.remove(event) }
            reply(command, nonce, ["evt": event])
            if command == "SUBSCRIBE" { sendInitialState(for: event) }
        case "GET_CHANNEL":
            // A contextless Activity has no channel; the one it was opened from only places it.
            guard !application.isContextless, args["channel_id"] as? String == instance.location.channelID.description else {
                return fail(command, nonce, .invalidChannel, "Invalid channel")
            }
            reply(command, nonce, channelPayload(model: model))
        case "GET_CHANNEL_PERMISSIONS":
            let permissions = model.embeddedActivities.session.flatMap { model.effectiveMessagePermissions(in: $0.channel) } ?? 0
            let hasChannel = instance.location.guildID != nil && !application.isContextless
            reply(command, nonce, ["permissions": String(hasChannel ? permissions : 0)])
        case "GET_ACTIVITY_INSTANCE_CONNECTED_PARTICIPANTS":
            reply(command, nonce, ["participants": participantsPayload()])
        case "GET_CONTEXT":
            var surface: [String: Any] = ["type": 0]
            if !application.isContextless {
                surface["channel_id"] = instance.location.channelID.description
                surface["guild_id"] = instance.location.guildID?.description
            }
            reply(command, nonce, ["surface": surface, "launch": [String: Any](), "platform": "desktop"])
        case "SET_ACTIVITY":
            var activity = args["activity"] as? [String: Any] ?? [:]
            activity["name"] = application.name
            activity["type"] = activity["type"] ?? 0
            reply(command, nonce, activity)
        case "SET_CONFIG":
            reply(command, nonce, ["use_interactive_pip": false])
        case "SET_ORIENTATION_LOCK_STATE", "CAPTURE_LOG", "SEND_ANALYTICS_EVENT":
            reply(command, nonce, nil)
        case "GET_PLATFORM_BEHAVIORS":
            reply(command, nonce, [String: Any]())
        case "ENCOURAGE_HW_ACCELERATION":
            reply(command, nonce, ["enabled": true])
        case "USER_SETTINGS_GET_LOCALE":
            reply(command, nonce, ["locale": Locale.preferredLanguages.first ?? "en-US"])
        case "GET_CURRENT_USER":
            reply(command, nonce, currentUserPayload(includesFlags: true))
        case "OPEN_EXTERNAL_LINK":
            guard let string = args["url"] as? String, let url = URL(string: string),
                  url.scheme == "https" || url.scheme == "http"
            else { return fail(command, nonce, .invalidPayload, "Invalid URL") }
            reply(command, nonce, ["opened": await openExternally(url)])
        case "OPEN_INVITE_DIALOG":
            guard !application.isContextless, instance.location.guildID.flatMap({ model.serverRailGuildsByID[$0] }) != nil else {
                return fail(command, nonce, .invalidChannel, "Invites are unavailable in this channel")
            }
            model.presentActivityInviteCreation(for: instance)
            reply(command, nonce, nil)
        case "REQUEST_PROXY_TICKET_REFRESH":
            do {
                let ticket = try await model.accountSession().provider.embeddedActivityProxyTicket(
                    application.id, channelID: application.isContextless ? nil : instance.location.channelID
                )
                reply(command, nonce, ["ticket": ticket])
            } catch {
                fail(command, nonce, .invalidCommand, "Could not renew the app session")
            }
        default:
            fail(command, nonce, .invalidCommand, "\(command) is not supported by SakuraCord")
        }
    }

    private func authorize(nonce: String, args: [String: Any], model: AppModel) async {
        let scopes = Self.scopes(args["scope"] ?? args["scopes"])
        guard args["client_id"].map({ $0 as? String == application.id.description }) ?? true, !scopes.isEmpty else {
            return fail("AUTHORIZE", nonce, .invalidPayload, "Invalid authorization request")
        }
        let request = EmbeddedActivityAuthorizationRequest(
            applicationID: application.id,
            scopes: scopes,
            // Like Discord's client, bind the grant to a state of our own when
            // the Activity supplies none.
            state: (args["state"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString,
            codeChallenge: args["code_challenge"] as? String,
            codeChallengeMethod: args["code_challenge_method"] as? String,
            location: instance.location,
            channelType: channelType
        )
        let account = model.accountSession()
        do {
            let granted = try await model.embeddedActivityConsent(to: request, launchID: launchID, account: account)
            guard !isStopped else { return }
            let code = try await account.provider.authorizeEmbeddedActivity(request, granted: granted)
            reply("AUTHORIZE", nonce, ["code": code])
        } catch {
            fail("AUTHORIZE", nonce, .oauth2, error.localizedDescription)
        }
    }

    private static func scopes(_ value: Any?) -> [String] {
        let scopes = (value as? [String]) ?? (value as? String)?.split(separator: " ").map(String.init) ?? []
        return scopes.filter { !$0.isEmpty }
    }

    // MARK: Events

    func participantsChanged() {
        guard subscriptions.contains("ACTIVITY_INSTANCE_PARTICIPANTS_UPDATE") else { return }
        dispatch("ACTIVITY_INSTANCE_PARTICIPANTS_UPDATE", ["participants": participantsPayload()])
    }

    private func sendInitialState(for event: String) {
        switch event {
        case "ACTIVITY_LAYOUT_MODE_UPDATE": dispatch(event, ["layout_mode": 0])
        case "THERMAL_STATE_UPDATE": dispatch(event, ["thermal_state": 0])
        case "CURRENT_USER_UPDATE": dispatch(event, currentUserPayload(includesFlags: true))
        case "ACTIVITY_INSTANCE_PARTICIPANTS_UPDATE": participantsChanged()
        default: break
        }
    }

    private func observeVoice() {
        guard let model, !isStopped else { return }
        withObservationTracking {
            _ = model.voiceStates
            _ = model.voiceParticipants
            _ = model.isLocallySpeaking
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.voiceChanged()
                self?.observeVoice()
            }
        }
    }

    private func voiceChanged() {
        guard let model, !isStopped, !application.isContextless else { return }
        // Speaking belongs to the Activity's channel only when it is the call's.
        var speaking: Set<String> = []
        if model.activeVoiceChannel?.id == instance.location.channelID {
            speaking = Set(model.voiceParticipants.filter(\.isSpeaking).map(\.userID))
            if model.isLocallySpeaking, let id = model.currentUser?.id { speaking.insert(id.description) }
        }
        for userID in speaking.subtracting(speakingUserIDs) where subscriptions.contains("SPEAKING_START") {
            dispatch("SPEAKING_START", ["user_id": userID, "channel_id": instance.location.channelID.description])
        }
        for userID in speakingUserIDs.subtracting(speaking) where subscriptions.contains("SPEAKING_STOP") {
            dispatch("SPEAKING_STOP", ["user_id": userID, "channel_id": instance.location.channelID.description])
        }
        speakingUserIDs = speaking
        let states = currentVoiceStates()
        if subscriptions.contains("VOICE_STATE_UPDATE") {
            for (userID, state) in states where voiceStates[userID] != state {
                dispatch("VOICE_STATE_UPDATE", userVoicePayload(state, model: model))
            }
        }
        voiceStates = states
    }

    private func currentVoiceStates() -> [UserID: VoiceParticipantState] {
        model?.voiceStates.filter { $0.value.channelID == instance.location.channelID } ?? [:]
    }

    // MARK: Payloads

    /// Discord's type for the hosting channel.
    private var channelType: Int {
        model?.embeddedActivities.session?.channel.discordCommandType ?? 0
    }

    private func channelPayload(model: AppModel) -> [String: Any] {
        let channel = model.embeddedActivities.session?.channel
        var payload: [String: Any] = [
            "id": instance.location.channelID.description,
            "type": channelType,
            "name": channel?.name ?? "",
            "voice_states": currentVoiceStates().values.map { userVoicePayload($0, model: model) },
            "messages": [Any](),
        ]
        payload["guild_id"] = instance.location.guildID?.description
        return payload
    }

    private func userVoicePayload(_ state: VoiceParticipantState, model: AppModel) -> [String: Any] {
        [
            "mute": state.isMuted || state.isSelfMuted,
            "nick": model.membersByID[state.userID]?.guildNickname ?? "",
            "user": userPayload(state.userID, includesFlags: true),
            "voice_state": [
                "mute": state.isMuted, "deaf": state.isDeafened, "self_mute": state.isSelfMuted,
                "self_deaf": state.isSelfDeafened, "suppress": state.isSuppressed,
            ],
            "volume": 100,
        ]
    }

    private func participantsPayload() -> [[String: Any]] {
        let participants = model?.embeddedActivities.session?.instance?.participants ?? instance.participants
        var seen = Set<UserID>()
        return participants.compactMap { participant in
            guard seen.insert(participant.userID).inserted else { return nil }
            var user = userPayload(participant.userID, includesFlags: true)
            user["nickname"] = model?.membersByID[participant.userID]?.guildNickname
            return user
        }
    }

    private func currentUserPayload(includesFlags: Bool) -> [String: Any] {
        guard let id = model?.currentUser?.id else { return [:] }
        return userPayload(id, includesFlags: includesFlags)
    }

    /// The SDK's user shape. READY's user has no flags and no null avatar.
    private func userPayload(_ userID: UserID, includesFlags: Bool) -> [String: Any] {
        let user = activityUser(userID)
        var payload: [String: Any] = [
            "id": userID.description,
            "username": user?.username ?? "",
            "discriminator": user?.discriminator ?? "0",
        ]
        if let avatar = user?.avatarURL.flatMap(Self.avatarHash) { payload["avatar"] = avatar }
        guard includesFlags else { return payload }
        payload["global_name"] = user.map { $0.displayName as Any } ?? NSNull()
        payload["bot"] = user?.isBot ?? false
        payload["flags"] = user?.publicFlags ?? 0
        payload["public_flags"] = user?.publicFlags ?? 0
        payload["avatar_decoration_data"] = NSNull()
        return payload
    }

    private func activityUser(_ userID: UserID) -> User? {
        guard let model else { return nil }
        if model.currentUser?.id == userID { return model.currentUser }
        return model.membersByID[userID]?.user
            ?? model.embeddedActivities.session?.channel.recipients.first { $0.id == userID }
    }

    private static func avatarHash(_ url: URL) -> String? {
        let parts = url.pathComponents
        guard parts.count >= 4, parts[1] == "avatars" else { return nil }
        return (parts[3] as NSString).deletingPathExtension
    }

    private static func foundationValue(_ value: JSONValue) -> Any {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        else { return NSNull() }
        return object
    }
}

extension EmbeddedActivityHost: WKNavigationDelegate, WKUIDelegate {
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        // The Activity and its embeds navigate freely inside the iframe; the
        // relay page itself never leaves, and links aimed at it open in the
        // browser. Once stopped, it unloads, which ends the Activity's audio.
        guard !isStopped, navigationAction.targetFrame?.isMainFrame == true,
              let url = navigationAction.request.url, url != Self.hostURL
        else { return decisionHandler(.allow) }
        decisionHandler(.cancel)
        if navigationAction.navigationType == .linkActivated { Task { await openExternally(url) } }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard !isStopped else { return }
        model?.embeddedActivities.session?.phase = .failed("\(application.name) stopped unexpectedly.")
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url, url.scheme == "https" { Task { await openExternally(url) } }
        return nil
    }

    /// Every way an Activity can send a link to the browser asks first, as
    /// `OPEN_EXTERNAL_LINK` does.
    private func openExternally(_ url: URL) async -> Bool {
        // A popup's task can run after the Activity ended; its prompt would be stale.
        guard let model, !isStopped else { return false }
        let opened = await model.embeddedActivities.ask(.openLink(url), applicationName: application.name, launchID: launchID)
            && !isStopped
        if opened { NSWorkspace.shared.open(url) }
        return opened
    }

    func webView(
        _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.deny)
    }
}

/// `WKUserContentController` retains its handlers; this breaks the cycle.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var host: EmbeddedActivityHost?

    init(_ host: EmbeddedActivityHost) {
        self.host = host
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { host?.receive(message) }
    }
}
