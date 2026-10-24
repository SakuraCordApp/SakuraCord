import SakuraCordModels

/// Conversation kinds whose right sidebar is shown or hidden independently,
/// matching Discord: the DM profile, group DM people, and server member list.
nonisolated enum InspectorContext: CaseIterable, Sendable {
    case server
    case directMessage
    case groupDirectMessage

    init(channelKind: ChannelKindValue?) {
        switch channelKind {
        case .directMessage: self = .directMessage
        case .groupDirectMessage: self = .groupDirectMessage
        default: self = .server
        }
    }
}

nonisolated struct InspectorVisibility: Equatable, Sendable {
    var server = true
    var directMessage = true
    var groupDirectMessage = true

    subscript(context: InspectorContext) -> Bool {
        get {
            switch context {
            case .server: server
            case .directMessage: directMessage
            case .groupDirectMessage: groupDirectMessage
            }
        }
        set {
            switch context {
            case .server: server = newValue
            case .directMessage: directMessage = newValue
            case .groupDirectMessage: groupDirectMessage = newValue
            }
        }
    }
}

extension AppModel {
    var inspectorContext: InspectorContext { InspectorContext(channelKind: selectedChannel?.kind) }

    /// The right sidebar for the selected conversation's kind; each kind keeps its own state.
    var showInspector: Bool {
        get { inspectorVisibility[inspectorContext] }
        set {
            var visibility = inspectorVisibility
            visibility[inspectorContext] = newValue
            applyInspectorVisibility(visibility)
        }
    }

    /// Hiding a server or group DM sidebar drops its member profile so reopening shows the list.
    func applyInspectorVisibility(_ visibility: InspectorVisibility) {
        inspectorVisibility = visibility
        if !showInspector, inspectorContext != .directMessage {
            dismissInspectorProfile()
        }
    }
}
