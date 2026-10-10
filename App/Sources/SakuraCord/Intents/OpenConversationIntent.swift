import AppIntents
import Foundation
import SakuraCordModels

struct OpenConversationIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Conversation"
    static let description = IntentDescription("Opens a conversation in SakuraCord.")

    @Parameter(title: "Conversation")
    var target: ConversationEntity

    init() {}

    init(target: ConversationEntity) {
        self.target = target
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$target)")
    }

    func perform() async throws -> some IntentResult {
        let identifier = target.id
        try await Self.open(identifier)
        return .result()
    }

    /// A Spotlight item from another saved account switches to that account
    /// before opening the conversation.
    @MainActor
    private static func open(_ identifier: ConversationEntityID) async throws {
        var model = try await IntentModelAccess.requireWorkspaceModel()
        if model.activeAccountID != identifier.accountID {
            guard let account = model.savedAccounts.first(where: { $0.accountID == identifier.accountID }) else {
                throw IntentError.accountUnavailable
            }
            guard await model.switchAccount(to: account.accountID) else {
                throw IntentError.switchAccount(account.resolvedDisplayName)
            }
            model = try await IntentModelAccess.requireWorkspaceModel()
            guard model.activeAccountID == identifier.accountID else {
                throw IntentError.switchAccount(account.resolvedDisplayName)
            }
        }
        model.navigate(to: identifier.channelID)
    }
}
