import AppKit
import SakuraCordModels
import SwiftUI

struct JoinServerView: View {
    let model: AppModel
    @Environment(\.windowModalContext) private var dismiss
    @Environment(\.windowModalAvailableSize) private var availableSize
    @State private var input = ""
    @State private var reference: ServerInviteReference?
    @State private var validationError: String?

    var body: some View {
        let width = min(390, availableSize.width)
        VStack(spacing: 0) {
            if let reference {
                let card = NativeTimelineInviteLayout(reference: reference, index: 0, origin: .zero,
                    maximumWidth: width, model: model, isOwnMessage: false, fillsWidth: true)
                ScrollView(.vertical) {
                    JoinServerPreview(card: card) { activate(reference, card: card, expands: $0) }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(card.frame.height, max(80, availableSize.height - 65)))
            } else {
                JoinServerInput(text: $input, error: validationError, submit: resolve)
            }
            Divider()
            JoinServerFooter(hasPreview: reference != nil, isWorking: isJoining,
                             canContinue: !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                             back: { if reference != nil { reference = nil } else { dismiss?() } },
                             proceed: resolve)
        }
        .frame(width: width)
        .windowModalDismissDisabled(isJoining)
        .onChange(of: input) { validationError = nil }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Join a Server")
    }

    private var isJoining: Bool {
        reference.flatMap { model.serverInvites.entries[$0]?.invite }.map {
            model.serverInvites.joining.contains($0.guildID)
        } ?? false
    }

    private func activate(_ reference: ServerInviteReference, card: NativeTimelineInviteLayout, expands: Bool) {
        if expands {
            if !model.serverInvites.expanded.insert(reference).inserted {
                model.serverInvites.expanded.remove(reference)
            }
        } else if card.invite?.unsupportedJoinReason != nil,
                  card.invite.flatMap({ model.serverRailGuildsByID[$0.guildID] }) == nil {
            NSWorkspace.shared.open(reference.url)
        } else {
            model.startAccountChildTask(account: model.accountSession()) { model, _ in
                if await model.activateServerInvite(reference) { dismiss?(allowsDisabled: true) }
            }
        }
    }

    private func resolve() {
        guard !isJoining else { return }
        guard let parsed = ServerInviteReference(input) else {
            validationError = "Enter a Discord server invite, such as discord.gg/invite-code."
            reference = nil
            return
        }
        validationError = nil
        reference = parsed
        model.loadServerInvite(parsed, refresh: true)
    }
}

private struct JoinServerInput: View {
    @Binding var text: String
    let error: String?
    let submit: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "link").foregroundStyle(.secondary)
                TextField("Invite link or code", text: $text)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .tint(SakuraCordAccentColor.color)
                    .focused($isFocused)
                    .accessibilityIdentifier("server-invite-input")
                    .onSubmit(submit)
            }
            .padding(.horizontal, 20)
            .frame(height: 64)
            .contentShape(Rectangle())
            .onTapGesture { isFocused = true }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
                    .padding(.horizontal, 20).padding(.bottom, 12)
            }
        }
        .task { await Task.yield(); isFocused = true }
    }
}

private struct JoinServerFooter: View {
    let hasPreview: Bool
    let isWorking: Bool
    let canContinue: Bool
    let back: () -> Void
    let proceed: () -> Void

    var body: some View {
        HStack {
            JoinServerGlassButton(symbol: hasPreview ? "chevron.left" : "xmark",
                                  label: hasPreview ? "Edit Invite" : "Cancel", action: back)
            Spacer(minLength: 16)
            JoinServerGlassButton(symbol: hasPreview ? "arrow.clockwise" : "arrow.right",
                                  label: hasPreview ? "Refresh Invite" : "Continue", primary: !hasPreview, action: proceed)
                .disabled(!canContinue)
        }
        .padding(12)
        .disabled(isWorking)
    }
}

private struct JoinServerGlassButton: View {
    let symbol: String
    let label: String
    var primary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: symbol)
                .font(.body.weight(.semibold))
                .padding(.horizontal, 16)
                .frame(height: 40)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(primary ? .regular.tint(SakuraCordAccentColor.color).interactive() : .regular.interactive(), in: Capsule())
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct JoinServerPreview: View {
    let card: NativeTimelineInviteLayout
    let activate: (Bool) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            NativeInvitePreview(card: card)
                .allowsHitTesting(false)
            if let details = card.detailsFrame {
                Button { activate(true) } label: { Color.clear.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(card.isExpanded ? "Hide Details" : "Show Details")
                    .frame(width: details.width, height: details.height)
                    .offset(x: details.minX, y: details.minY)
            }
            if card.buttonFrame.height > 0 {
                Button(card.buttonTitle) { activate(false) }
                    .buttonStyle(NativeInvitePreviewButtonStyle(title: card.buttonTitle))
                    .accessibilityLabel(card.buttonTitle)
                    .disabled(card.isDisabled)
                    .keyboardShortcut(.defaultAction)
                    .frame(width: card.buttonFrame.width, height: card.buttonFrame.height)
                    .offset(x: card.buttonFrame.minX, y: card.buttonFrame.minY)
            }
        }
        .frame(width: card.frame.width, height: card.frame.height)
    }
}

private struct NativeInvitePreviewButtonStyle: ButtonStyle {
    let title: String
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        // SwiftUI owns pointer, keyboard and accessibility activation; Core Graphics
        // draws the same control and press curve as the native message timeline.
        configuration.label.hidden()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                NativeInviteButtonSurface(title: title, isHovered: isHovered && isEnabled,
                                          pressProgress: configuration.isPressed && isEnabled ? 1 : 0,
                                          isEnabled: isEnabled)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .animation(reduceMotion ? nil : .easeOut(duration: NativeTimelineComponentButtonVisualState.pressAnimationDuration),
                               value: configuration.isPressed)
            }
            .contentShape(Capsule())
            .onModalHover { isHovered = $0 }
    }
}

private struct NativeInviteButtonSurface: NSViewRepresentable, Animatable {
    var title: String
    var isHovered: Bool
    var pressProgress: CGFloat
    var isEnabled: Bool
    var animatableData: CGFloat {
        get { pressProgress }
        set { pressProgress = newValue }
    }

    func makeNSView(context: Context) -> Surface { Surface() }
    func updateNSView(_ view: Surface, context: Context) {
        view.title = title
        view.isHovered = isHovered
        view.pressProgress = pressProgress
        view.isEnabled = isEnabled
        view.needsDisplay = true
    }

    final class Surface: NSView {
        var title = ""
        var isHovered = false
        var pressProgress: CGFloat = 0
        var isEnabled = true
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            NativeTimelineRowPainter.sakuraCordButton(title: title, frame: bounds, isHovered: isHovered,
                pressProgress: pressProgress, colors: [.sakuraCordAccentColor], isEnabled: isEnabled)
        }
    }
}
