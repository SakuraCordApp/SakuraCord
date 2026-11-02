import SakuraCordModels
import SwiftUI

private enum PollCreationField: Hashable {
    case question
    case answer(Int)
}

/// Rows sit 8 points inside the 32-point panel, so their 24-point corners and
/// 32-point controls stay concentric with it.
struct PollCreationView: View {
    let model: AppModel
    let channelID: ChannelID
    @Environment(\.windowModalContext) private var dismiss
    @Environment(\.windowModalAvailableSize) private var availableSize
    @State private var draft = PollDraft()
    @State private var nextAnswerID = 3
    @State private var isSending = false
    @State private var error: String?
    @FocusState private var focus: PollCreationField?

    var body: some View {
        VStack(spacing: 0) {
            questionField
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    // A scoped container keeps scrolled glass clipped to the list.
                    GlassEffectContainer(spacing: 0) {
                        VStack(spacing: InterfaceScale.metric(8)) {
                            ForEach(Array($draft.answers.enumerated()), id: \.element.id) { index, $answer in
                                PollCreationAnswerRow(model: model, answer: $answer, placeholder: "Answer \(index + 1)",
                                                      canRemove: draft.answers.count > 1, focus: $focus,
                                                      submit: { advance(from: answer.id, proxy: proxy) },
                                                      remove: { remove(answer.id) })
                            }
                            if draft.answers.count < 10 {
                                PollCreationAddAnswerRow { addAnswer(proxy: proxy) }
                                    .transition(.opacity)
                            }
                            PollCreationSettingRow(symbol: "clock", title: "Duration") {
                                Picker("Duration", selection: $draft.durationHours) {
                                    ForEach(PollDraft.durations, id: \.self) { Text(durationLabel($0)).tag($0) }
                                }
                                .labelsHidden().pickerStyle(.menu).fixedSize()
                            }
                            .padding(.top, InterfaceScale.metric(8))
                            PollCreationSettingRow(symbol: "checklist", title: "Allow Multiple Answers") {
                                Toggle("Allow Multiple Answers", isOn: $draft.allowsMultipleAnswers)
                                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                                    .tint(SakuraCordAccentColor.color)
                            }
                        }
                        .padding(InterfaceScale.metric(8))
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: min(560, max(160, availableSize.height - 140)))
                .fixedSize(horizontal: false, vertical: true)
                .clipped()
            }
            if let error {
                Text(error).font(.interface(.callout)).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, InterfaceScale.metric(20)).padding(.vertical, InterfaceScale.metric(12))
            }
            Divider()
            HStack {
                ModalGlassButton(symbol: "xmark", label: "Cancel") { dismiss?() }
                Spacer(minLength: InterfaceScale.metric(16))
                ModalGlassButton(symbol: "chart.bar.xaxis", label: "Create Poll", primary: true, action: create)
                    .disabled(isSending || draft.validationError != nil)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(InterfaceScale.metric(12))
        }
        .frame(width: min(440, availableSize.width))
        .disabled(isSending)
        .windowModalDismissDisabled(isSending)
        .onChange(of: draft) { error = nil }
        .task { await Task.yield(); focus = .question }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Create a Poll")
    }

    private var questionField: some View {
        HStack(alignment: .firstTextBaseline, spacing: InterfaceScale.metric(11)) {
            Image(systemName: "chart.bar.xaxis")
                .font(.interfaceSystem(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Ask a question", text: $draft.question, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.interfaceSystem(size: 19))
                .lineLimit(1 ... 4)
                .tint(SakuraCordAccentColor.color)
                .focused($focus, equals: .question)
                .onSubmit { focus = draft.answers.first.map { .answer($0.id) } }
            if draft.question.utf16.count > 260 {
                Text("\(draft.question.utf16.count)/300").font(.interface(.caption)).monospacedDigit()
                    .foregroundStyle(draft.question.utf16.count > 300 ? .red : .secondary)
            }
        }
        .padding(.horizontal, InterfaceScale.metric(18)).padding(.vertical, InterfaceScale.metric(17))
        .frame(maxWidth: .infinity, minHeight: InterfaceScale.metric(58), alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { focus = .question }
    }

    // Explicit transactions also animate the modal panel, which sizes to this content.
    private func addAnswer(proxy: ScrollViewProxy) {
        guard draft.answers.count < 10 else { return }
        let id = nextAnswerID
        nextAnswerID += 1
        withAnimation(.snappy(duration: 0.25)) {
            draft.answers.append(.init(id: id, text: ""))
            proxy.scrollTo(id)
        }
        focus = .answer(id)
    }

    private func remove(_ id: Int) {
        guard let index = draft.answers.firstIndex(where: { $0.id == id }), draft.answers.count > 1 else { return }
        withAnimation(.snappy(duration: 0.25)) { _ = draft.answers.remove(at: index) }
        if focus == .answer(id) { focus = .answer(draft.answers[min(index, draft.answers.count - 1)].id) }
    }

    private func advance(from id: Int, proxy: ScrollViewProxy) {
        guard let index = draft.answers.firstIndex(where: { $0.id == id }) else { return }
        if draft.answers.indices.contains(index + 1) {
            focus = .answer(draft.answers[index + 1].id)
        } else if !draft.answers[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            addAnswer(proxy: proxy)
        }
    }

    private func create() {
        guard !isSending, draft.validationError == nil else { return }
        isSending = true
        Task {
            if await model.createPoll(draft, in: channelID).consumedComposer {
                dismiss?(allowsDisabled: true)
            } else {
                error = model.errorMessage ?? "Couldn't create the poll. Try again."
            }
            isSending = false
        }
    }

    private func durationLabel(_ hours: Int) -> String {
        switch hours {
        case 1: "1 hour"
        case 4, 8: "\(hours) hours"
        case 24: "24 hours"
        case 72: "3 days"
        case 168: "1 week"
        default: "2 weeks"
        }
    }
}

private struct PollCreationAnswerRow: View {
    let model: AppModel
    @Binding var answer: PollAnswer
    let placeholder: String
    let canRemove: Bool
    var focus: FocusState<PollCreationField?>.Binding
    let submit: () -> Void
    let remove: () -> Void
    @State private var showsEmojiPicker = false

    var body: some View {
        HStack(spacing: InterfaceScale.metric(8)) {
            emojiButton
            TextField(placeholder, text: $answer.text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1 ... 3)
                .tint(SakuraCordAccentColor.color)
                .focused(focus, equals: .answer(answer.id))
                .onSubmit(submit)
                .frame(maxWidth: .infinity, alignment: .leading)
            if answer.text.utf16.count > 45 {
                Text("\(answer.text.utf16.count)/55").font(.interface(.caption)).monospacedDigit()
                    .foregroundStyle(answer.text.utf16.count > 55 ? .red : .secondary)
            }
            if canRemove {
                HoverActionButton(systemImage: "xmark", help: "Remove Answer", diameter: InterfaceScale.metric(32), action: remove)
                    .foregroundStyle(.secondary)
            }
        }
        .modifier(ModalRowBackground(isHighlighted: focus.wrappedValue == .answer(answer.id)) { focus.wrappedValue = .answer(answer.id) })
        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
    }

    private var emojiButton: some View {
        Button { showsEmojiPicker.toggle() } label: {
            Group {
                if let emoji = answer.emoji {
                    PollAnswerEmoji(emoji: emoji, size: InterfaceScale.metric(20))
                } else {
                    Image(systemName: "face.smiling").font(.interfaceSystem(size: 17)).foregroundStyle(.secondary)
                }
            }
            .frame(width: InterfaceScale.metric(32), height: InterfaceScale.metric(32))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help(answer.emoji == nil ? "Add Emoji" : "Change Emoji")
        .accessibilityLabel(answer.emoji == nil ? "Add Emoji" : "Change Emoji")
        .background {
            StableReactionPickerPresenter(isPresented: $showsEmojiPicker, preferredEdge: .maxX,
                                          accessibilityIdentifier: "poll-answer-emoji-picker") {
                EmojiPickerView(model: model, useCase: .reaction(guildID: model.selectedGuildID),
                                dismiss: { showsEmojiPicker = false }, select: { activation in
                    switch activation.selection {
                    case .native(let value): answer.emoji = EmojiReference(rawToken: value)
                    case .custom(let value): answer.emoji = EmojiReference(rawToken: value.messageToken)
                    }
                    showsEmojiPicker = false
                })
            }
        }
        .contextMenu {
            if answer.emoji != nil { Button("Remove Emoji") { answer.emoji = nil } }
        }
    }
}

private struct PollCreationAddAnswerRow: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: InterfaceScale.metric(8)) {
                Image(systemName: "plus").font(.interface(.body).weight(.semibold)).frame(width: InterfaceScale.metric(32), height: InterfaceScale.metric(32))
                Text("Add Answer")
            }
            .foregroundStyle(isHovered ? .primary : .secondary)
            .padding(InterfaceScale.metric(8))
            .frame(maxWidth: .infinity, minHeight: InterfaceScale.metric(48), alignment: .leading)
            .background(.quaternary.opacity(isHovered ? 0.5 : 0), in: RoundedRectangle(cornerRadius: InterfaceScale.metric(24), style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: InterfaceScale.metric(24), style: .continuous)
                    .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .opacity(isHovered ? 0 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: InterfaceScale.metric(24), style: .continuous))
        }
        .buttonStyle(.plain)
        .onModalHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

private struct PollCreationSettingRow<Control: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: InterfaceScale.metric(8)) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: InterfaceScale.metric(32), height: InterfaceScale.metric(32))
                .accessibilityHidden(true)
            Text(title)
            Spacer(minLength: InterfaceScale.metric(8))
            control().padding(.trailing, InterfaceScale.metric(6))
        }
        .modifier(ModalRowBackground())
    }
}
