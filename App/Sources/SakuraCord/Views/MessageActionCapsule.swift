import AppKit
import CoreText
import MessageRendering
import SakuraCordModels
import SwiftUI

/// Holding Shift alone swaps the hover capsule's quick reactions for
/// message utilities, as in Discord.
enum MessageActionShiftPolicy {
    static func isActive(_ modifierFlags: NSEvent.ModifierFlags) -> Bool {
        modifierFlags.intersection([.shift, .command, .option, .control]) == .shift
    }
}

struct MessageActionCapsule: View {
    let model: AppModel
    let message: Message
    let canEdit: Bool
    let canDelete: Bool
    let canReact: Bool
    let showsQuickReactions: Bool
    let showsShiftActions: Bool
    @Binding var isReactionPickerPresented: Bool
    let retry: (() -> Void)?
    let edit: () -> Void
    let reply: (() -> Void)?
    let forward: (() -> Void)?
    let react: (String) -> Void
    let copy: () -> Void
    let copyLink: () -> Void
    let copyMessageID: () -> Void
    let markUnread: () -> Void
    let togglePin: (() -> Void)?
    let showMoreActions: () -> Void
    let delete: () -> Void
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var reduceMotion: Bool { systemReduceMotion || !model.animates(.overlays) }

    var body: some View {
        if message.outboxState == .failed {
            HoverActionPill {
                if message.canRetrySending, let retry {
                    HoverActionButton(
                        systemImage: "arrow.clockwise",
                        help: "Retry send",
                        action: retry
                    )
                }
                HoverActionButton(
                    systemImage: "doc.on.doc",
                    help: "Copy text",
                    action: copy
                )
            }
        } else {
            // The leading section carries its own trailing spacing, so it
            // stays in place while empty without widening the pill.
            HoverActionPill(spacing: 0) {
                leadingActions
                HStack(spacing: HoverActionPillMetrics.spacing) {
                    if canReact {
                        ReactionActionMenu(
                            model: model,
                            guildID: message.guildID,
                            isPickerPresented: $isReactionPickerPresented,
                            react: react
                        )
                        .id("reaction-picker-\(message.id)-toolbar")
                    }
                    if let reply {
                        HoverActionButton(systemImage: "arrowshape.turn.up.left", help: "Reply", action: reply)
                    }
                    if canEdit {
                        HoverActionButton(systemImage: "pencil", help: "Edit message", action: edit)
                    }
                    if let forward {
                        HoverActionButton(
                            systemImage: "arrowshape.turn.up.right",
                            help: "Forward",
                            action: forward
                        )
                    }
                    trailingAction
                }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : .smooth(duration: 0.3), value: showsShiftActions)
        }
    }

    /// Quick reactions slide up and out as the Shift utilities rise from
    /// below; releasing Shift plays the same motion in reverse.
    private var leadingActions: some View {
        ZStack(alignment: .trailing) {
            if showsShiftActions {
                HStack(spacing: HoverActionPillMetrics.spacing) {
                    HoverActionButton(systemImage: "number.square", help: "Copy Message ID", action: copyMessageID)
                    HoverActionButton(systemImage: "link", help: "Copy Link", action: copyLink)
                    HoverActionButton(systemImage: "envelope.badge", help: "Mark Unread", action: markUnread)
                    if let togglePin {
                        HoverActionButton(
                            systemImage: message.isPinned ? "pin.slash" : "pin",
                            help: message.isPinned ? "Unpin Message" : "Pin Message",
                            action: togglePin
                        )
                    }
                }
                .padding(.trailing, HoverActionPillMetrics.spacing)
                .transition(variantTransition(isShift: true))
            } else if showsQuickReactions {
                HStack(spacing: HoverActionPillMetrics.spacing) {
                    QuickReactionSection(model: model, message: message, react: react)
                }
                .padding(.trailing, HoverActionPillMetrics.spacing)
                .transition(variantTransition(isShift: false))
            }
        }
        .clipped()
    }

    /// Shift turns More into Delete. Shift is held when it is clicked, so
    /// deletion skips confirmation as it does from the context menu.
    private var trailingAction: some View {
        ZStack {
            if showsShiftActions, canDelete {
                HoverActionButton(systemImage: "trash", help: "Delete message", role: .destructive, action: delete)
                    .transition(variantTransition(isShift: true))
            } else {
                HoverActionButton(systemImage: "ellipsis", help: "More", action: showMoreActions)
                    .transition(variantTransition(isShift: false))
            }
        }
        .clipped()
    }

    private func variantTransition(isShift: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: isShift ? .bottom : .top).combined(with: .opacity)
    }
}

/// Its own view so that only this section tracks the model state it reads.
private struct QuickReactionSection: View {
    let model: AppModel
    let message: Message
    let react: (String) -> Void

    var body: some View {
        let quickReactions = model.quickReactions(for: message)
        if !quickReactions.isEmpty {
            ForEach(quickReactions) { reaction in
                QuickReactionButton(reaction: reaction, customEmojiURLsByID: model.customEmojiURLsByID) {
                    react(reaction.token)
                }
            }
            // One load per section; on ForEach it would run per emoji.
            HoverActionPillDivider()
                .task { await model.loadDiscordEmojiSettings() }
        }
    }
}

private struct QuickReactionButton: View {
    let reaction: QuickReaction
    let customEmojiURLsByID: CustomEmojiImageURLs
    let action: () -> Void

    var body: some View {
        let token = Reaction(emoji: reaction.token, count: 0)
        Button(action: action) {
            HoverActionControlLabel(diameter: HoverActionPillMetrics.controlDiameter) {
                MessageReactionEmoji(
                    reaction: token,
                    url: MessageReactionPresentation.emojiURL(for: token, customEmojiURLsByID: customEmojiURLsByID),
                    size: InterfaceScale.metric(18)
                )
            }
        }
        .buttonStyle(.plain)
        // Discord marks an applied quick reaction only in its tooltip and
        // label; clicking it removes that reaction.
        .help(":\(reaction.name):\n\(reaction.isApplied ? "Click to remove" : "Click to react")")
        .accessibilityLabel(
            reaction.isApplied ? "Click to remove \(reaction.name)" : "Click to react with \(reaction.name)"
        )
    }
}

private struct ReactionActionMenu: View {
    let model: AppModel
    let guildID: GuildID?
    @Binding var isPickerPresented: Bool
    var presentation: ReactionActionMenuPresentation = .toolbar
    let react: (String) -> Void
    @State private var isHovering = false

    var body: some View {
        let width = presentation.width
        let height = presentation.height
        let cornerRadius = presentation.cornerRadius
        ZStack {
            ConcentricRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(backgroundColor)
                .overlay {
                    ConcentricRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                        .padding(0.5)
                }

            Button {
                presentPicker()
            } label: {
                SakuraCordSystemSymbol.emojiFaceGrinningImage
                    .symbolVariant(.none)
                    .font(.system(
                        size: InterfaceScale.fontSize(
                            NSFont.preferredFont(forTextStyle: .callout).pointSize + 2
                        ),
                        weight: .medium
                    ))
                    .foregroundStyle(.primary)
                    .opacity(presentation == .inline ? 0.8 : 1)
                    .frame(width: width, height: height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: width, height: height)
        // Hover tracks the square frame, so clicks and the pointer cover it
        // too, as on the other hover action controls.
        .contentShape(Rectangle())
        .pointerStyle(.link)
        .onModalHover { isHovering = $0 }
        .help("Add reaction")
        .background {
            StableReactionPickerPresenter(
                isPresented: $isPickerPresented,
                preferredEdge: presentation.popoverEdge,
                accessibilityIdentifier: presentation.pickerAccessibilityIdentifier
            ) {
                EmojiPickerView(
                    model: model,
                    useCase: .reaction(guildID: guildID ?? model.selectedGuildID),
                    allowsPersistentSelection: true,
                    dismiss: { isPickerPresented = false },
                    select: { activation in
                        switch activation.selection {
                        case let .native(value): react(value)
                        case let .custom(emoji): react(emoji.messageToken)
                        }
                        if !activation.keepsPickerPresented {
                            isPickerPresented = false
                        }
                    }
                )
            }
            .frame(
                width: width,
                height: height
            )
        }
    }

    private var backgroundColor: Color {
        if isHovering { return Color.primary.opacity(0.14) }
        return presentation == .inline ? Color.primary.opacity(0.09) : .clear
    }

    private var borderColor: Color {
        presentation == .inline && isHovering ? Color.primary.opacity(0.28) : .clear
    }

    private func presentPicker() {
        guard !isPickerPresented else {
            isPickerPresented = false
            return
        }
        Task { @MainActor in
            await Task.yield()
            isPickerPresented = true
        }
    }
}

enum ReactionActionMenuPresentation {
    case toolbar
    case inline

    var width: CGFloat {
        self == .toolbar
            ? HoverActionPillMetrics.controlDiameter
            : InterfaceScale.metric(30)
    }
    var height: CGFloat {
        self == .toolbar
            ? HoverActionPillMetrics.controlDiameter
            : MessageReactionMetrics.pillHeight
    }
    var cornerRadius: CGFloat {
        self == .toolbar
            ? HoverActionPillMetrics.controlDiameter / 2
            : InterfaceScale.metric(9)
    }
    var popoverEdge: NSRectEdge {
        StableReactionPickerAnchorPolicy.preferredEdge(isInline: self == .inline)
    }
    var pickerAccessibilityIdentifier: String {
        self == .inline ? "reaction-picker-inline" : "reaction-picker-toolbar"
    }
}
