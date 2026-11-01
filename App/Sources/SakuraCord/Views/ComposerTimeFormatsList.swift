import AppKit
import MessageRendering
import SakuraCordModels
import SwiftUI

public struct TimeMentionEntry: Equatable {
    public var prefix: String
    public var query: String
    public var suffix: String

    public init(prefix: String = "", query: String = "", suffix: String = "") {
        self.prefix = prefix
        self.query = query
        self.suffix = suffix
    }
}

private struct FlattenedOption: Identifiable {
    let index: Int
    let option: DiscordParsedTimeCandidate.Option
    let hasDividerBefore: Bool

    var id: String { option.id }
    var optionID: String { option.id }
}

struct TimeFormatsAutocompleteList: View {
    let heading: String
    let candidates: [DiscordParsedTimeCandidate]
    let selectedIndex: Int
    let highlight: (Int) -> Void
    let select: (DiscordParsedTimeCandidate.Option) -> Void
    var cancel: (() -> Void)?
    var cornerRadius: CGFloat = ChatChromeMetrics.composerCornerRadius
    var keyboardSelectionRevision: Int = 0

    private var allFlattenedOptions: [FlattenedOption] {
        var items: [FlattenedOption] = []
        var running = 0
        for (candidateIndex, candidate) in candidates.enumerated() {
            for (optionIndex, option) in candidate.options.enumerated() {
                let showDivider = candidateIndex > 0 && optionIndex == 0
                items.append(FlattenedOption(index: running, option: option, hasDividerBefore: showDivider))
                running += 1
            }
        }
        return items
    }

    var body: some View {
        let options = allFlattenedOptions
        let selectedID = options.indices.contains(selectedIndex) ? options[selectedIndex].id : nil
        ComposerAutocompletePanel(heading: heading.uppercased(), cornerRadius: cornerRadius) {
            VStack(spacing: 0) {
                ComposerSuggestionList(
                    rows: options,
                    selectedID: selectedID,
                    keyboardSelectionRevision: keyboardSelectionRevision,
                    maximumHeight: InterfaceScale.metric(360),
                    rowHeight: { item in
                        item.hasDividerBefore ? InterfaceScale.metric(46) : InterfaceScale.metric(36)
                    },
                    highlight: { item in
                        if item.index != selectedIndex { highlight(item.index) }
                    },
                    activate: { item in
                        select(item.option)
                    },
                    content: { item in
                        VStack(spacing: 0) {
                            if item.hasDividerBefore {
                                Divider()
                                    .padding(.horizontal, InterfaceScale.metric(8))
                                    .frame(height: InterfaceScale.metric(10))
                            }
                            TimeFormatAutocompleteRow(
                                item: item,
                                isSelected: options.indices.contains(selectedIndex) && options[selectedIndex].optionID == item.optionID,
                                select: { select(item.option) },
                                cornerRadius: max(0, cornerRadius - 6)
                            )
                        }
                    }
                )

                Divider()
                    .padding(.horizontal, InterfaceScale.metric(8))

                TimeMentionHelpStrip(cancel: cancel)
            }
        }
    }
}

private struct TimeFormatAutocompleteRow: View {
    let item: FlattenedOption
    let isSelected: Bool
    let select: () -> Void
    var cornerRadius: CGFloat = 6

    var body: some View {
        HStack(spacing: InterfaceScale.metric(8)) {
            Text(item.option.displayText)
                .font(.interfaceSystem(size: 14).monospacedDigit())
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.25), value: item.option.displayText)
                .foregroundStyle(Color.primary)
                .padding(.horizontal, InterfaceScale.metric(8))
                .padding(.vertical, InterfaceScale.metric(4))
                .background(
                    Color.primary.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: InterfaceScale.metric(4), style: .continuous)
                )

            Spacer()

            if let badge = item.option.badgeText {
                Text(badge)
                    .font(.interfaceSystem(size: 12))
                    .foregroundStyle(Color.secondary)
            }
        }
        .padding(.horizontal, InterfaceScale.metric(10))
        .frame(height: InterfaceScale.metric(36))
        .contentShape(Rectangle())
        .background(
            isSelected
                ? Color.accentColor.opacity(0.18)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }
}

struct TimeMentionHelpStrip: View {
    var cancel: (() -> Void)?

    var body: some View {
        HStack(spacing: InterfaceScale.metric(8)) {
            Text("@time")
                .font(.interfaceSystem(size: 12, weight: .bold))
                .foregroundStyle(Color.secondary)

            Text("Refer to a time dynamically in the viewer's time zone")
                .font(.interfaceSystem(size: 12))
                .foregroundStyle(Color.secondary)

            Spacer()
        }
        .padding(.horizontal, InterfaceScale.metric(14))
        .padding(.vertical, InterfaceScale.metric(7))
    }
}

struct TimeMentionNSTextFieldView: View {
    @Binding var query: String
    let onCommit: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: InterfaceScale.metric(6)) {
            HStack(spacing: InterfaceScale.metric(4)) {
                Image(systemName: "clock")
                    .font(.interfaceSystem(size: 12, weight: .semibold))
                Text("@time")
                    .font(.interfaceSystem(size: 13, weight: .semibold))
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, InterfaceScale.metric(6))
            .padding(.vertical, InterfaceScale.metric(3))
            .background(
                Color.primary.opacity(0.12),
                in: RoundedRectangle(cornerRadius: InterfaceScale.metric(4), style: .continuous)
            )

            TextField("Type a date or time...", text: $query)
                .textFieldStyle(.plain)
                .font(.interfaceSystem(size: 14))
                .onSubmit(onCommit)
                .onExitCommand(perform: onCancel)
        }
        .padding(InterfaceScale.metric(6))
        .background(
            RoundedRectangle(cornerRadius: InterfaceScale.metric(6), style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: InterfaceScale.metric(6), style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                }
        )
    }
}

final class TimeMentionNSTextField: NSTextField {
    var onCancel: (() -> Void)?
    var onAccept: (() -> Void)?
    var onCommand: ((ComposerAutocompleteCommand) -> Bool)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 126 { // Up arrow
            if onCommand?(.previous) == true { return }
        }
        if event.keyCode == 125 { // Down arrow
            if onCommand?(.next) == true { return }
        }
        if event.keyCode == 36 || event.keyCode == 76 || event.keyCode == 48 { // Return or Tab
            onAccept?()
            return
        }
        if event.keyCode == 53 { // Escape
            onCancel?()
            return
        }
        if event.keyCode == 51 || event.keyCode == 117, stringValue.isEmpty { // Backspace
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            onCancel?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct TimeMentionFieldRepresentable: NSViewRepresentable {
    @Binding var text: String
    let onCommand: (ComposerAutocompleteCommand) -> Bool
    let onAccept: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> TimeMentionNSTextField {
        let field = TimeMentionNSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .interfaceSystemFont(ofSize: 15)
        field.textColor = .labelColor
        field.placeholderString = "Type a date or time (e.g. 24 October, in 2 hours)..."
        field.delegate = context.coordinator
        field.onCancel = onCancel
        field.onAccept = onAccept
        field.onCommand = onCommand
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ nsView: TimeMentionNSTextField, context: Context) {
        context.coordinator.parent = self
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.onCancel = onCancel
        nsView.onAccept = onAccept
        nsView.onCommand = onCommand
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TimeMentionFieldRepresentable

        init(_ parent: TimeMentionFieldRepresentable) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                return parent.onCommand(.previous)
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                return parent.onCommand(.next)
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) || commandSelector == #selector(NSResponder.insertTab(_:)) {
                parent.onAccept()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            if commandSelector == #selector(NSResponder.deleteBackward(_:)), parent.text.isEmpty {
                parent.onCancel()
                return true
            }
            return false
        }
    }
}

struct TimeMentionInputView: View {
    @Binding var query: String
    var prefix: String = ""
    var suffix: String = ""
    var mentionPresentations: [String: MentionPresentation] = [:]
    let onAccept: () -> Void
    let onCancel: () -> Void
    let onCommand: (ComposerAutocompleteCommand) -> Bool

    var body: some View {
        HStack(spacing: InterfaceScale.metric(6)) {
            if !prefix.isEmpty {
                TimeMentionSurroundingContentView(
                    text: prefix,
                    mentionPresentations: mentionPresentations
                )
            }
            HStack(spacing: InterfaceScale.metric(6)) {
                HStack(spacing: InterfaceScale.metric(4)) {
                    Text("@time")
                        .font(.interfaceSystem(size: 13, weight: .semibold))
                }
                .foregroundStyle(Color.primary)
                .padding(.horizontal, InterfaceScale.metric(6))
                .padding(.vertical, InterfaceScale.metric(2.5))
                .background(
                    Color.primary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: InterfaceScale.metric(4), style: .continuous)
                )

                TimeMentionFieldRepresentable(
                    text: $query,
                    onCommand: onCommand,
                    onAccept: onAccept,
                    onCancel: onCancel
                )
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, InterfaceScale.metric(6))
            .padding(.vertical, InterfaceScale.metric(3))
            .background(
                RoundedRectangle(cornerRadius: InterfaceScale.metric(5), style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                    .background(
                        RoundedRectangle(cornerRadius: InterfaceScale.metric(5), style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.35))
                    )
            )

            if !suffix.isEmpty {
                TimeMentionSurroundingContentView(
                    text: suffix,
                    mentionPresentations: mentionPresentations
                )
            }
        }
        .frame(minHeight: ChatChromeMetrics.composerControlHeight)
    }
}

struct TimeMentionSurroundingContentView: View {
    let text: String
    let mentionPresentations: [String: MentionPresentation]

    private var segments: [MessageDocument.Segment] {
        MessageDocumentCache.shared.document(for: text).segments
    }

    var body: some View {
        HStack(spacing: InterfaceScale.metric(4)) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case let .markdown(content):
                    Text(content)
                        .font(.interfaceSystem(size: 15))
                        .foregroundStyle(Color.primary)
                case let .mention(mention):
                    let presentation = mentionPresentations[mention.rawToken]
                        ?? MentionPresentation.fallback(for: mention)
                    TimeMentionSurroundingPillView(presentation: presentation)
                case let .customEmoji(emoji):
                    if let image = ComposerEmojiImageStore.shared.cachedImage(for: emoji.rawToken) {
                        Image(nsImage: image)
                            .resizable()
                            .frame(width: InterfaceScale.metric(18), height: InterfaceScale.metric(18))
                    } else {
                        Text(":\(emoji.name):")
                            .font(.interfaceSystem(size: 15))
                            .foregroundStyle(Color.primary)
                    }
                }
            }
        }
    }
}

struct TimeMentionSurroundingPillView: View {
    let presentation: MentionPresentation
    @State private var now = Date.now

    var body: some View {
        HStack(spacing: InterfaceScale.metric(4)) {
            if let systemImage = presentation.systemImage {
                Image(systemName: systemImage)
                    .font(.interfaceSystem(size: 12))
            }
            Text(currentLabel)
                .font(.interfaceSystem(size: 14, weight: presentation.isTimestamp ? .regular : .medium).monospacedDigit())
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.25), value: currentLabel)
        }
        .foregroundStyle(textColor)
        .padding(.horizontal, InterfaceScale.metric(6))
        .padding(.vertical, InterfaceScale.metric(2.5))
        .background(
            backgroundColor,
            in: RoundedRectangle(cornerRadius: InterfaceScale.metric(4.5), style: .continuous)
        )
        .task {
            if case let .timestamp(_, style) = presentation.target, style == "R" {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    now = .now
                }
            }
        }
    }

    private var currentLabel: String {
        if case let .timestamp(date, style) = presentation.target, style == "R" {
            return DiscordTimestampFormatter.formatted(date: date, style: "R", now: now)
        }
        return presentation.label
    }

    private var textColor: Color {
        if presentation.isTimestamp {
            return Color.primary
        }
        if let hex = presentation.colorHex, hex != 0 {
            return Color(nsColor: MentionAttachmentRenderer.mentionColor(hex: hex))
        }
        return Color.accentColor
    }

    private var backgroundColor: Color {
        if presentation.isTimestamp {
            return Color.primary.opacity(0.12)
        }
        if let hex = presentation.colorHex, hex != 0 {
            return Color(nsColor: MentionAttachmentRenderer.mentionColor(hex: hex)).opacity(0.16)
        }
        return Color.accentColor.opacity(0.16)
    }
}
