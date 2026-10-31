import Foundation

/// What an AutoMod alert post reports about the message it caught. The
/// post's author is the member who sent that message.
public struct AutoModerationAlert: Equatable, Sendable {
    public var content: String
    public var ruleName: String?
    public var channelID: ChannelID?
    public var keyword: String?
    public var matchedContent: String?
    /// An alert-only rule lets the message through instead of blocking it.
    public var isFlagged: Bool
}

public extension Message {
    var autoModerationAlert: AutoModerationAlert? {
        guard type == .autoModerationAction,
              let embed = embeds.first(where: { $0.type == "auto_moderation_message" }) else { return nil }
        func field(_ name: String) -> String? {
            embed.fields.first { $0.name == name }.flatMap { $0.value.isEmpty ? nil : $0.value }
        }
        return AutoModerationAlert(
            content: embed.description ?? "",
            ruleName: field("rule_name"),
            channelID: field("channel_id").flatMap(ChannelID.init),
            keyword: field("keyword"),
            matchedContent: field("keyword_matched_content"),
            isFlagged: field("decision_outcome") == "flagged"
        )
    }
}
