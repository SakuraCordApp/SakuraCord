import AppKit
import DiscordProtocol
import SakuraCordModels
import WebKit

/// Hosts one Activity as the parent side of Discord's Embedded App SDK.
///
/// The Activity loads as the web view's top-level document, so its proxy
/// cookies are first-party. With no parent window the SDK posts its RPC frames
/// to its own window; a document-start script hands those to this host, and
/// replies arrive as `message` events from discord.com, as they would inside
/// Discord's iframe. The account credential never enters the page.
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
    private let frameID = UUID().uuidString.lowercased()
    private var subscriptions: Set<String> = []
    private var speakingUserIDs: Set<String> = []
    private var voiceStates: [UserID: VoiceParticipantState] = [:]
    private var isStopped = false

    init(model: AppModel, instance: EmbeddedActivityInstance, application: EmbeddedActivityApplication, proxyTicket: String) {
        self.model = model
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
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(
            source: Self.bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page
        ))
        controller.add(WeakMessageHandler(self), contentWorld: .page, name: Self.handlerName)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.underPageBackgroundColor = .black
        #if DEBUG
            webView.isInspectable = true
        #endif
        voiceStates = currentVoiceStates()
        observeVoice()
        webView.load(URLRequest(url: launchURL(proxyTicket: proxyTicket)))
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: .page)
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
    }

    private func launchURL(proxyTicket: String) -> URL {
        var components = URLComponents(url: application.activityURL, resolvingAgainstBaseURL: false)!
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        var items = [
            URLQueryItem(name: "instance_id", value: instance.compositeInstanceID),
            URLQueryItem(name: "location_id", value: instance.location.id),
            URLQueryItem(name: "launch_id", value: instance.instanceID),
            URLQueryItem(name: "theme", value: isDark ? "dark" : "light"),
            URLQueryItem(name: "discord_proxy_ticket", value: proxyTicket),
        ]
        if let guildID = instance.location.guildID {
            items.append(URLQueryItem(name: "guild_id", value: guildID.description))
        }
        items += [
            URLQueryItem(name: "channel_id", value: instance.location.channelID.description),
            URLQueryItem(name: "frame_id", value: frameID),
            URLQueryItem(name: "platform", value: "desktop"),
            URLQueryItem(name: "discord_shim", value: "1"),
        ]
        components.queryItems = items
        return components.url!
    }

    // MARK: Transport

    fileprivate func receive(_ message: WKScriptMessage) {
        guard !isStopped, message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.host == application.activityURL.host(),
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
            "window.dispatchEvent(new MessageEvent('message', {data: [opcode, payload], origin: 'https://discord.com', source: window}));",
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
            guard args["channel_id"] as? String == instance.location.channelID.description else {
                return fail(command, nonce, .invalidChannel, "Invalid channel")
            }
            reply(command, nonce, channelPayload(model: model))
        case "GET_CHANNEL_PERMISSIONS":
            let permissions = activityChannel(model).flatMap(model.effectiveMessagePermissions) ?? 0
            reply(command, nonce, ["permissions": String(instance.location.guildID == nil ? 0 : permissions)])
        case "GET_ACTIVITY_INSTANCE_CONNECTED_PARTICIPANTS":
            reply(command, nonce, ["participants": participantsPayload()])
        case "GET_CONTEXT":
            var surface: [String: Any] = ["type": 0, "channel_id": instance.location.channelID.description]
            surface["guild_id"] = instance.location.guildID?.description
            reply(command, nonce, ["surface": surface, "launch": [String: Any](), "platform": "desktop"])
        case "SET_ACTIVITY":
            var activity = args["activity"] as? [String: Any] ?? [:]
            activity["name"] = application.name
            activity["type"] = activity["type"] ?? 0
            reply(command, nonce, activity)
        case "SET_CONFIG":
            reply(command, nonce, ["use_interactive_pip": false])
        case "SET_ORIENTATION_LOCK_STATE", "CAPTURE_LOG":
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
            let opened = await model.embeddedActivities.ask(.openLink(url), applicationName: application.name) && !isStopped
            if opened { NSWorkspace.shared.open(url) }
            reply(command, nonce, ["opened": opened])
        case "REQUEST_PROXY_TICKET_REFRESH":
            do {
                let ticket = try await model.accountSession().provider.embeddedActivityProxyTicket(
                    application.id, channelID: instance.location.channelID
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
            state: args["state"] as? String,
            codeChallenge: args["code_challenge"] as? String,
            codeChallengeMethod: args["code_challenge_method"] as? String,
            location: instance.location
        )
        let provider = model.accountSession().provider
        do {
            let preview = try await provider.embeddedActivityAuthorizationPreview(request)
            guard !isStopped else { return }
            if !preview.isAuthorized {
                guard await model.embeddedActivities.ask(.authorize(scopes: scopes), applicationName: preview.applicationName),
                      !isStopped
                else { return fail("AUTHORIZE", nonce, .oauth2, "User cancelled authorization") }
            }
            let code = try await provider.authorizeEmbeddedActivity(request)
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
        guard let model, !isStopped else { return }
        var speaking = Set(model.voiceParticipants.filter(\.isSpeaking).map(\.userID))
        if model.isLocallySpeaking, let id = model.currentUser?.id { speaking.insert(id.description) }
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

    private func activityChannel(_ model: AppModel) -> Channel? {
        model.activeVoiceChannel?.id == instance.location.channelID
            ? model.activeVoiceChannel
            : model.embeddedActivities.session?.channel
    }

    private func channelPayload(model: AppModel) -> [String: Any] {
        let channel = activityChannel(model)
        let type = switch channel?.kind {
        case .directMessage: 1
        case .groupDirectMessage: 3
        default: 2
        }
        var payload: [String: Any] = [
            "id": instance.location.channelID.description,
            "type": type,
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
            ?? activityChannel(model)?.recipients.first { $0.id == userID }
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

    /// Forwards the SDK's `[opcode, payload]` frames; every other message keeps
    /// the page's own `postMessage`.
    private static let bridgeScript = """
    (() => {
        const handler = window.webkit.messageHandlers.\(handlerName);
        const post = window.postMessage.bind(window);
        window.postMessage = function (message, targetOrigin, transfer) {
            if (Array.isArray(message) && Number.isInteger(message[0]) && message[0] >= 0 && message[0] <= 3
                && message[1] !== null && typeof message[1] === 'object') {
                try { handler.postMessage(JSON.parse(JSON.stringify(message))); } catch (error) {}
                return;
            }
            return post(message, targetOrigin, transfer);
        };
    })();
    """
}

extension EmbeddedActivityHost: WKNavigationDelegate, WKUIDelegate {
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        // Embedded players and the Activity itself stay inside; a top-level
        // navigation away from the Activity opens in the browser instead.
        guard navigationAction.targetFrame?.isMainFrame == true,
              let url = navigationAction.request.url,
              url.host() != application.activityURL.host(), url.scheme != "about"
        else { return decisionHandler(.allow) }
        decisionHandler(.cancel)
        if navigationAction.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url, url.scheme == "https" { NSWorkspace.shared.open(url) }
        return nil
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
