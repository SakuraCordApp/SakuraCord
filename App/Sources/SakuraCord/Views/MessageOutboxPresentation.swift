import Foundation
import SakuraCordModels

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
