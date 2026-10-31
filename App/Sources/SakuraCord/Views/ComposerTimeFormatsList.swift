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
}

struct TimeFormatsAutocompleteList: View {
    let heading: String
    let candidates: [DiscordParsedTimeCandidate]
    let selectedIndex: Int
    let highlight: (Int) -> Void
    let select: (DiscordParsedTimeCandidate.Option) -> Void
    let cornerRadius: CGFloat
    let keyboardSelectionRevision: Int

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

    private var contentHeight: CGFloat {
        let totalItems = allFlattenedOptions.count
        guard totalItems > 0 else { return InterfaceScale.metric(60) }
        let dividers = max(0, candidates.count - 1)
        let rawHeight = CGFloat(totalItems) * InterfaceScale.metric(36)
            + CGFloat(dividers) * InterfaceScale.metric(12)
            + InterfaceScale.metric(8)
        return min(InterfaceScale.metric(280), max(InterfaceScale.metric(80), rawHeight))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(heading.uppercased())
                .font(.interfaceSystem(size: 11, weight: .bold))
                .foregroundStyle(Color.secondary)
                .padding(.horizontal, InterfaceScale.metric(14))
                .padding(.top, InterfaceScale.metric(10))
                .padding(.bottom, InterfaceScale.metric(6))

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: InterfaceScale.metric(2)) {
                        ForEach(allFlattenedOptions) { item in
                            if item.hasDividerBefore {
                                Divider()
                                    .padding(.vertical, InterfaceScale.metric(4))
                                    .padding(.horizontal, InterfaceScale.metric(10))
                            }

                            let isSelected = item.index == selectedIndex
                            Button {
                                select(item.option)
                            } label: {
                                HStack {
                                    Text(item.option.displayText)
                                        .font(.interfaceSystem(size: 14))
                                        .foregroundStyle(Color.primary)
                                        .padding(.horizontal, InterfaceScale.metric(8))
                                        .padding(.vertical, InterfaceScale.metric(4))
                                        .background(
                                            Color.primary.opacity(0.10),
                                            in: RoundedRectangle(cornerRadius: InterfaceScale.metric(4), style: .continuous)
                                        )
                                    Spacer()
                                }
                                .padding(.horizontal, InterfaceScale.metric(10))
                                .padding(.vertical, InterfaceScale.metric(4))
                                .contentShape(Rectangle())
                                .background(
                                    isSelected
                                        ? Color.accentColor.opacity(0.18)
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: InterfaceScale.metric(6), style: .continuous)
                                )
                            }
                            .buttonStyle(.plain)
                            .id(item.index)
                            .onHover { hovering in
                                if hovering { highlight(item.index) }
                            }
                        }
                    }
                    .padding(.horizontal, InterfaceScale.metric(6))
                    .padding(.bottom, InterfaceScale.metric(6))
                }
                .frame(height: contentHeight)
                .onChange(of: keyboardSelectionRevision) { _, _ in
                    proxy.scrollTo(selectedIndex)
                }
            }
        }
        .commandPanelSurface(cornerRadius: cornerRadius)
    }
}

struct TimeMentionHelpStrip: View {
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: InterfaceScale.metric(8)) {
            Text("@time")
                .font(.interfaceSystem(size: 13, weight: .bold))
                .foregroundStyle(Color.primary)

            Text("Refer to a time dynamically in the viewer's time zone")
                .font(.interfaceSystem(size: 12))
                .foregroundStyle(Color.secondary)

            Spacer()

            Button(action: cancel) {
                Image(systemName: "xmark")
                    .font(.interfaceSystem(size: 11, weight: .semibold))
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, InterfaceScale.metric(14))
        .padding(.vertical, InterfaceScale.metric(8))
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            window?.makeFirstResponder(self)
        }
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
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ nsView: TimeMentionNSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.onCancel = onCancel
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
    let onAccept: () -> Void
    let onCancel: () -> Void
    let onCommand: (ComposerAutocompleteCommand) -> Bool

    var body: some View {
        HStack(spacing: InterfaceScale.metric(6)) {
            if !prefix.isEmpty {
                Text(prefix)
                    .font(.interfaceSystem(size: 15))
                    .foregroundStyle(Color.primary)
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
                Text(suffix)
                    .font(.interfaceSystem(size: 15))
                    .foregroundStyle(Color.primary)
            }
        }
        .frame(minHeight: ChatChromeMetrics.composerControlHeight)
    }
}
