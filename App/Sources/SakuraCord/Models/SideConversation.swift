import SakuraCordModels

/// A side chat, or a thread presented at full width.
enum SideConversation: Equatable {
    /// A thread or forum post, read through the thread store.
    case thread(MessageThreadSummary, isFullWidth: Bool)
    /// A thread being composed. It becomes `.thread` once Discord creates it.
    case threadCreation(ThreadCreationDraft)
    /// The selected voice channel's text chat.
    case voiceChat(ChannelID)
    /// A Server Guide resource channel, read forward from its first message.
    case guideResource(GuildID, ChannelID)
    /// A Browse Channels preview. It borrows the selected channel and restores
    /// `returnTo` when closed.
    case channelPreview(ChannelID, returnTo: ChannelID?)

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.thread(lhsThread, lhsFullWidth), .thread(rhsThread, rhsFullWidth)):
            lhsThread == rhsThread && lhsFullWidth == rhsFullWidth
        case let (.threadCreation(lhsDraft), .threadCreation(rhsDraft)):
            lhsDraft === rhsDraft
        case let (.voiceChat(lhsID), .voiceChat(rhsID)):
            lhsID == rhsID
        case let (.guideResource(lhsGuild, lhsChannel), .guideResource(rhsGuild, rhsChannel)):
            lhsGuild == rhsGuild && lhsChannel == rhsChannel
        case let (.channelPreview(lhsID, lhsReturn), .channelPreview(rhsID, rhsReturn)):
            lhsID == rhsID && lhsReturn == rhsReturn
        default:
            false
        }
    }

    /// Threads open above a voice chat, preview or resource and return to it
    /// when closed. The other kinds belong to the primary workspace.
    var isThread: Bool {
        switch self {
        case .thread, .threadCreation: true
        case .voiceChat, .guideResource, .channelPreview: false
        }
    }

    var isFullWidth: Bool {
        if case .thread(_, isFullWidth: true) = self { return true }
        return false
    }

    var capabilities: SideConversationCapabilities {
        switch self {
        case .thread, .threadCreation:
            SideConversationCapabilities(
                composerDestination: .thread,
                closeHelp: "Close thread"
            )
        case .voiceChat:
            SideConversationCapabilities(
                presentsPrimaryConversation: true,
                composerDestination: .channel,
                closeHelp: "Close voice channel chat"
            )
        case .guideResource:
            SideConversationCapabilities(closeHelp: "Close preview")
        case .channelPreview:
            SideConversationCapabilities(
                presentsPrimaryConversation: true,
                composerDestination: .channel,
                canAddToChannelList: true,
                closeHelp: "Close preview"
            )
        }
    }
}

/// What a side chat's pane offers.
struct SideConversationCapabilities: Equatable {
    /// The pane shows the selected channel through the primary conversation.
    var presentsPrimaryConversation = false
    /// The composer that sends into this conversation; nil when read-only.
    var composerDestination: MessageComposerDestination?
    var canAddToChannelList = false
    var closeHelp: String
}

/// Closing the top thread reveals its context; replacing the context closes both.
struct SideConversationStack: Equatable {
    /// A voice chat, channel preview or Guide resource.
    var context: SideConversation? {
        didSet { assert(context?.isThread != true) }
    }

    /// A thread or thread draft.
    var thread: SideConversation? {
        didSet { assert(thread?.isThread != false) }
    }
}

/// What occupies the workspace's trailing column.
enum SupplementaryPane: Equatable {
    case sideConversation(SideConversation)
    case memberInspector
    case messageSearch
}

/// The primary content and trailing pane shown by the workspace.
struct WorkspacePresentation: Equatable {
    enum Primary: Equatable {
        case guildPage(GuildWorkspacePage)
        case friends
        case channel(ChannelContent)
        case fullWidthThread
    }

    enum ChannelContent: Equatable {
        case chat
        case forum
        case voice
    }

    let primary: Primary
    let supplementaryPane: SupplementaryPane?

    /// - Parameter sideConversation: The presented side chat, already
    ///   validated against the workspace by AppModel.
    init(
        guildPage: GuildWorkspacePage?,
        isFriendsPresented: Bool,
        channelKind: ChannelKindValue?,
        sideConversation: SideConversation?,
        showsMessageSearch: Bool,
        showsInspector: Bool
    ) {
        // Visible search keeps its results beside any channel conversation,
        // including a full-width thread opened from a result.
        if sideConversation?.isFullWidth == true {
            primary = .fullWidthThread
            supplementaryPane = Self.channelPane(nil, showsMessageSearch, showsInspector)
            return
        }
        let sidePane = sideConversation.map(SupplementaryPane.sideConversation)
        if let guildPage {
            primary = .guildPage(guildPage)
            supplementaryPane = sidePane
            return
        }
        if isFriendsPresented {
            primary = .friends
            supplementaryPane = nil
            return
        }
        switch channelKind {
        case .voice:
            primary = .channel(.voice)
            supplementaryPane = showsMessageSearch ? .messageSearch : sidePane
        case .forum:
            primary = .channel(.forum)
            supplementaryPane = Self.channelPane(sidePane, showsMessageSearch, showsInspector)
        default:
            primary = .channel(.chat)
            supplementaryPane = Self.channelPane(sidePane, showsMessageSearch, showsInspector)
        }
    }

    /// The side chat shown in the trailing column, if any.
    var paneSideConversation: SideConversation? {
        if case .sideConversation(let conversation)? = supplementaryPane { return conversation }
        return nil
    }

    private static func channelPane(
        _ sidePane: SupplementaryPane?,
        _ showsMessageSearch: Bool,
        _ showsInspector: Bool
    ) -> SupplementaryPane? {
        if showsMessageSearch { return .messageSearch }
        return sidePane ?? (showsInspector ? .memberInspector : nil)
    }
}
