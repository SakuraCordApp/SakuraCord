import AppKit
import MessageRendering
import SakuraCordModels
import SwiftUI

extension NativeTimelineCanvasView {
    func setHoveredCommandPillMessageID(_ value: MessageID?) {
        guard hoveredCommandPillMessageID != value else { return }
        let old = hoveredCommandPillMessageID
        hoveredCommandPillMessageID = value
        for messageID in [old, value].compactMap({ $0 }) { invalidateVisibleMessageRow(messageID: messageID) }
    }

    func commandPillPointerHit(at point: CGPoint) -> MessageID? {
        guard let index = rowIndex(at: point.y), items.indices.contains(index), layouts.indices.contains(index),
              let pill = layouts[index].commandInvocationRegion?.pillFrame
        else { return nil }
        let local = CGPoint(x: point.x, y: point.y - displayedRowOrigin(at: index))
        return pill.contains(local) ? items[index].messageID : nil
    }

    /// Clicking the pill again closes its popover, as in Discord.
    func showCommandInvocation(for message: Message) {
        guard let model else { return }
        let identity = AnyHashable(message.id)
        if mentionPopoverCoordinator.isPresenting(identity: identity) {
            closeMentionPopover()
            return
        }
        closeMessageProfilePopover()
        closeServerTagPopover()
        model.loadMessageInteractionData(for: message)
        let messageID = message.id
        let anchor = StablePopoverAnchor(sourceView: self) { [weak self] in
            guard let self, let index = self.visibleMessageRowIndex(for: messageID),
                  let pill = layouts[index].commandInvocationRegion?.pillFrame
            else { return nil }
            return pill.offsetBy(dx: 0, dy: displayedRowOrigin(at: index))
        }
        showMentionPopover(
            AnyView(CommandInvocationPopover(model: model, message: message)),
            anchor: anchor,
            configuration: .commandInvocation,
            presentationIdentity: identity
        )
    }

    func commandInvocationAccessibilityElements(
        _ region: NativeTimelineRowLayout.CommandInvocationRegion,
        message: Message,
        rowIndex: Int,
        parent: NSAccessibilityElement
    ) -> [NSAccessibilityElement] {
        let commandName = message.interactionMetadata?.displayName ?? "command"
        let invokingUser = message.interactionMetadata?.user?.displayName ?? "Someone"
        return [
            accessibilityElement(
                role: .button, label: "\(invokingUser) used /\(commandName)", help: "Show profile",
                frame: accessibilityChildFrame(region.profileFrame, rowIndex: rowIndex), parent: parent
            ) { [weak self] in
                guard let self, let user = message.interactionMetadata?.user else { return false }
                self.showMessageProfile(
                    for: user, sourceMessage: message,
                    anchor: self.accessibilityChildFrame(region.profileFrame, rowIndex: rowIndex)
                )
                return true
            },
            accessibilityElement(
                role: .button, label: "/\(commandName)", help: "Show the command as typed",
                frame: accessibilityChildFrame(region.pillFrame, rowIndex: rowIndex), parent: parent
            ) { [weak self] in
                guard let self else { return false }
                self.showCommandInvocation(for: message)
                return true
            },
        ]
    }
}

extension StablePopoverConfiguration {
    static var commandInvocation: StablePopoverConfiguration {
        StablePopoverConfiguration(
            preferredEdge: .maxY,
            behavior: .transient,
            animates: true,
            ignoresMouseEvents: false,
            contentSizing: .constrained(CommandInvocationPopover.bubbleSize),
            stabilizesInitialContentSize: false
        )
    }
}

/// The command as typed, opened from the indicator above a bot's reply.
struct CommandInvocationPopover: View {
    /// Discord's bubble; a longer command wraps, then scrolls, inside it.
    static var bubbleSize: CGSize { CGSize(width: InterfaceScale.metric(350), height: InterfaceScale.metric(400)) }
    private static var insets: CGSize { CGSize(width: InterfaceScale.metric(12), height: InterfaceScale.metric(8)) }

    let model: AppModel
    let message: Message
    @Environment(\.stablePopoverPresentationContext) private var presentationContext

    private var entry: MessageInteractionDataStore.Entry? {
        model.messageInteractionData.entries[message.id]
    }

    var body: some View {
        let insets = Self.insets
        CommandLineLayout(maximumSize: CGSize(
            width: Self.bubbleSize.width - 2 * insets.width, height: Self.bubbleSize.height - 2 * insets.height
        )) {
            ScrollView { content }
        }
        // The popover first measures the spinner; follow the command as it arrives.
        .onGeometryChange(for: CGSize.self, of: \.size) { _ in presentationContext?.contentSizeDidChange?() }
        .padding(.horizontal, insets.width)
        .padding(.vertical, insets.height)
    }

    private var content: some View {
        Group {
            switch entry {
            case let .loaded(data):
                Text(commandText(data))
            // Discord keeps loading when it cannot read the options; the name alone invents nothing.
            case .failed:
                Text(verbatim: "/\(message.interactionMetadata?.displayName ?? "command")")
            case .loading, nil:
                ProgressView().controlSize(.small)
            }
        }
        .font(.interface(.body))
        .textSelection(.enabled)
    }

    private func commandText(_ data: MessageInteractionData) -> AttributedString {
        var text = AttributedString("/\(data.commandName)")
        append(data.options, to: &text)
        return text
    }

    private func append(_ options: [MessageInteractionData.Option], to text: inout AttributedString) {
        for option in options {
            if option.type.isStructural {
                text += AttributedString(" \(option.name)")
                append(option.options, to: &text)
                continue
            }
            text += AttributedString(" \(option.name): ")
            if let value = option.value { text += valueText(value, type: option.type) }
        }
    }

    private func valueText(_ value: String, type: ApplicationCommandOptionType) -> AttributedString {
        if type == .attachment { return AttributedString("[attachment]") }
        let token: String? = switch type {
        case .user: "<@\(value)>"
        case .channel: "<#\(value)>"
        case .role: "<@&\(value)>"
        // Like Discord, a mentionable is a role when one is known by that ID, otherwise a user.
        case .mentionable:
            RoleID(value).flatMap { model.mentionRole($0, in: message) } != nil ? "<@&\(value)>" : "<@\(value)>"
        default: nil
        }
        guard let mention = token.flatMap(RenderedMention.init(rawToken:)) else { return AttributedString(value) }
        let label = model.mentionPresentation(mention, in: message).label
        var styled = AttributedString(type == .channel ? "#\(label)" : label)
        styled.foregroundColor = SakuraCordAccentColor.color
        styled.backgroundColor = SakuraCordAccentColor.color.opacity(0.16)
        return styled
    }
}

/// One line when the command fits, wrapped beyond, scrolling past the maximum
/// height. The size ignores the proposal, which is still the spinner's size
/// when the command arrives.
private struct CommandLineLayout: Layout {
    let maximumSize: CGSize

    func sizeThatFits(proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = min(content.sizeThatFits(.unspecified).width, maximumSize.width)
        let height = content.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        return CGSize(width: width, height: min(height, maximumSize.height))
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
