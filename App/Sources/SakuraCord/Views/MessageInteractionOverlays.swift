import AppKit
import CoreText
import MessageRendering
import SakuraCordModels
import SwiftUI

nonisolated enum MessageOutboxPresentation {
    enum InteractionMode: Equatable {
        case disabled
        case failed
        case confirmed

        var allowsHoverActions: Bool {
            self != .disabled
        }

        var allowsMessageContextMenu: Bool {
            self != .disabled
        }

        var allowsMediaContextMenu: Bool {
            self == .confirmed
        }
    }

    static func interactionMode(for message: Message) -> InteractionMode {
        message.flags.contains(.ephemeral) ? .disabled : interactionMode(for: message.outboxState)
    }

    static func interactionMode(for state: OutboxState) -> InteractionMode {
        switch state {
        case .queued, .uploading, .sending, .awaitingReconciliation:
            .disabled
        case .failed:
            .failed
        case .confirmed:
            .confirmed
        }
    }

    /// Pending-interaction status replaces dimming; it is already muted.
    static func textOpacity(for message: Message) -> Double {
        message.flags.contains(.loading) ? 1 : contentOpacity(for: message.outboxState)
    }

    /// Discord labels a pending interaction from its loading flag, not its
    /// body: a local command row reports its own progress, and an app's
    /// deferred response is the app "thinking".
    static func interactionLoadingStatus(for message: Message, authorName: String) -> String? {
        guard message.flags.contains(.loading) else { return nil }
        if message.outboxState != .confirmed, !message.content.isEmpty { return message.content }
        return "\(authorName) is thinking…"
    }

    static func mediaOpacity(for state: OutboxState) -> Double {
        contentOpacity(for: state)
    }

    private static func contentOpacity(for state: OutboxState) -> Double {
        switch state {
        case .queued, .uploading, .sending, .awaitingReconciliation:
            0.55
        case .confirmed, .failed:
            1
        }
    }

    static let retryTitle = String(localized: "Retry")

    static func failureText(for message: Message) -> String {
        guard message.outboxState == .failed,
              case let .autoModeration(explanation) = message.sendFailure
        else { return "Failed" }
        let detail = explanation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return detail.isEmpty ? "This message was blocked by AutoMod." : detail
    }

    static func accessibilityStatus(for message: Message) -> String {
        guard message.outboxState == .failed,
              case let .autoModeration(explanation) = message.sendFailure
        else { return accessibilityStatus(for: message.outboxState) }
        let detail = explanation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return detail.isEmpty ? "Blocked by AutoMod" : "Blocked by AutoMod. \(detail)"
    }

    static func accessibilityStatus(for state: OutboxState) -> String {
        switch state {
        case .queued, .uploading, .sending:
            "Sending"
        case .awaitingReconciliation:
            "Waiting for confirmation"
        case .confirmed:
            "Sent"
        case .failed:
            "Failed"
        }
    }
}

enum MessageDeleteConfirmationPolicy {
    static func isBypassed(
        by modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        modifierFlags.contains(.shift)
    }
}

enum MessageReplySummary {
    nonisolated struct Prepared: Sendable {
        let source: String
        let text: String
        /// UTF-16 ranges of `text` inside spoilers. Reply bars never reveal
        /// them, so presentation conceals these ranges.
        let spoilerRanges: [NSRange]
    }

    private final class CachedValue {
        let prepared: Prepared

        init(_ prepared: Prepared) {
            self.prepared = prepared
        }
    }

    private static let values: NSCache<NSString, CachedValue> = {
        let cache = NSCache<NSString, CachedValue>()
        cache.countLimit = 2_000
        cache.totalCostLimit = 4 * 1_024 * 1_024
        return cache
    }()

    static let defaultMentionLabel: (RenderedMention) -> String = { mention in
        switch mention.kind {
        case .guildNavigation: GuildNavigationMention(rawValue: mention.id)?.title ?? mention.rawToken
        case .user: "@unknown-user"
        case .role: "@unknown-role"
        case .game, .broadcast, .command, .timestamp: MentionPresentation.fallback(for: mention).label
        case .channel: "#unknown-channel"
        case .channelLink: "Channel link"
        case .message: "Message link"
        }
    }

    /// Plain single-line text, including spoiler contents.
    static func text(
        content: String,
        mentionLabel: (RenderedMention) -> String = defaultMentionLabel
    ) -> String {
        summary(content: content, mentionLabel: mentionLabel).text
    }

    /// Single-line text with its spoiler ranges.
    static func summary(
        content: String,
        mentionLabel: (RenderedMention) -> String = defaultMentionLabel
    ) -> Prepared {
        let source = resolvedSource(content: content, mentionLabel: mentionLabel)
        if let cached = values.object(forKey: source as NSString) {
            return cached.prepared
        }
        let prepared = prepare(source)
        install(prepared)
        return prepared
    }

    /// Text for accessibility, which reads each spoiler as "Spoiler".
    static func accessibilityText(
        content: String,
        mentionLabel: (RenderedMention) -> String = defaultMentionLabel
    ) -> String {
        let prepared = summary(content: content, mentionLabel: mentionLabel)
        let text = NSMutableString(string: prepared.text)
        for range in prepared.spoilerRanges.reversed() {
            text.replaceCharacters(in: range, with: "Spoiler")
        }
        return text as String
    }

    static func preparation(
        content: String,
        mentionLabel: (RenderedMention) -> String
    ) -> String? {
        let source = resolvedSource(content: content, mentionLabel: mentionLabel)
        return values.object(forKey: source as NSString) == nil ? source : nil
    }

    private static func resolvedSource(
        content: String,
        mentionLabel: (RenderedMention) -> String
    ) -> String {
        let document = MessageDocumentCache.shared.document(for: content)
        return document.segments.reduce(into: "") { output, segment in
            switch segment {
            case let .markdown(value):
                output += value
            case let .customEmoji(emoji):
                output += ":\(emoji.name):"
            case let .mention(mention):
                output += mentionLabel(mention)
            }
        }
    }

    /// Collapses the rendered text's whitespace to single spaces. A collapsed
    /// space is a spoiler only inside one spoiler, and adjacent spoilers stay
    /// separate ranges.
    nonisolated static func prepare(_ source: String) -> Prepared {
        var text = ""
        var spoilerRanges: [NSRange] = []
        var length = 0
        var pendingSpace = false
        var previousSpoilerID: Int?
        var rangeSpoilerID: Int?

        func append(_ value: String, spoilerID: Int?) {
            let valueLength = value.utf16.count
            if let spoilerID {
                if let last = spoilerRanges.last,
                   NSMaxRange(last) == length,
                   rangeSpoilerID == spoilerID
                {
                    spoilerRanges[spoilerRanges.count - 1].length += valueLength
                } else {
                    spoilerRanges.append(NSRange(location: length, length: valueLength))
                    rangeSpoilerID = spoilerID
                }
            }
            text += value
            length += valueLength
        }

        for run in DiscordMarkdown.plainTextRuns(source) {
            for character in run.text {
                if character.isWhitespace {
                    pendingSpace = !text.isEmpty
                    continue
                }
                if pendingSpace {
                    append(
                        " ",
                        spoilerID: previousSpoilerID == run.spoilerID ? run.spoilerID : nil
                    )
                    pendingSpace = false
                }
                append(String(character), spoilerID: run.spoilerID)
                previousSpoilerID = run.spoilerID
            }
        }
        guard !text.isEmpty else {
            return Prepared(source: source, text: "Attachment", spoilerRanges: [])
        }
        return Prepared(source: source, text: text, spoilerRanges: spoilerRanges)
    }

    static func install(_ prepared: Prepared) {
        values.setObject(
            CachedValue(prepared),
            forKey: prepared.source as NSString,
            cost: prepared.source.utf8.count + prepared.text.utf8.count
        )
    }
}

struct MessageProfilePopoverContent: View {
    let model: AppModel
    let userID: UserID
    let requestID: UUID

    var body: some View {
        Group {
            if let presentation = model.liveProfilePresentation(for: .contextual),
               presentation.member.id == userID,
               presentation.requestID == requestID
            {
                ProfilePresentationContent(presentation: presentation, openProfile: model.expandProfile, userMenu: {
                    UserContextMenu.make(for: presentation.member.user, context: .init(guildID: presentation.guildID), model: model)
                }, sendMessage: model.sendProfileMessage)
                    .environment(\.profileCosmeticPolicy, model.cosmeticPolicy)
                    .environment(\.serverTagCardModel, model)
            } else {
                Color.clear.frame(width: InterfaceScale.metric(330), height: InterfaceScale.metric(250))
            }
        }
        .onDisappear {
            model.dismissContextualProfile(requestID: requestID)
        }
    }
}
