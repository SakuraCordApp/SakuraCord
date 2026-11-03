import SakuraCordModels
import SwiftUI

/// The application form and the approval greeting, which the official client presents as modals.
struct GuildJoinApplicationView: View {
    let model: AppModel
    let modal: GuildJoinRequestStore.Modal
    @Environment(\.windowModalContext) private var dismiss
    @Environment(\.windowModalAvailableSize) private var availableSize
    @State private var confirmsDiscard = false

    private var store: GuildJoinRequestStore { model.guildJoinRequests }
    private var guildName: String { model.joinRequestGuildName(modal.guildID) }
    private var iconURL: URL? { model.joinRequestGuildIconURL(modal.guildID) }
    private var hasAnswers: Bool { store.form?.fields.contains { $0.answer != nil } == true }

    var body: some View {
        VStack(spacing: 0) {
            switch modal.kind {
            case .form: form
            case .welcome: welcome
            }
        }
        .frame(width: min(modal.kind == .form ? 520 : 400, availableSize.width))
        .windowModalDismissDisabled(store.isWorking || (modal.kind == .form && hasAnswers))
        .alert("Are you sure? Your progress will be lost.", isPresented: $confirmsDiscard) {
            Button("Close Anyway", role: .destructive) { close() }
            Button("Cancel", role: .cancel) {}
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(modal.kind == .form ? "Application to \(guildName)" : "Welcome to \(guildName)")
    }

    private func close() {
        dismiss?(allowsDisabled: true)
    }

    @ViewBuilder private var form: some View {
        HStack(spacing: InterfaceScale.metric(12)) {
            GuildIconView(name: guildName, iconURL: iconURL, size: InterfaceScale.metric(40), cornerRadius: InterfaceScale.metric(12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: InterfaceScale.metric(2)) {
                Text(guildName).font(.interface(.headline)).lineLimit(1)
                if let form = store.form, let members = form.memberCount {
                    Text("\((form.onlineCount ?? 0).formatted()) Online · \(members.formatted()) Members")
                        .font(.interface(.callout)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(InterfaceScale.metric(20))
        Divider()
        if let form = store.form {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: InterfaceScale.metric(20)) {
                    VStack(alignment: .leading, spacing: InterfaceScale.metric(4)) {
                        Text("Answer a few questions to join \(guildName)").font(.interface(.title3).weight(.semibold))
                        // Rules-only screening admits the member at once; nobody reviews it.
                        if model.serverRailGuildsByID[modal.guildID]?.features.contains("MEMBER_VERIFICATION_MANUAL_APPROVAL") != false {
                            Text("The server admin will get back to you shortly after you submit.")
                                .font(.interface(.callout)).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(form.fields.indices, id: \.self) { index in
                        GuildJoinApplicationFieldEditor(field: Binding(
                            get: { store.form?.fields[index] ?? form.fields[index] },
                            set: { store.form?.fields[index] = $0 }
                        ))
                    }
                    Text("""
                    Make sure you have not entered your password or any other sensitive information. \
                    By applying, you give the server admins permission to message you regarding your application.
                    """)
                        .font(.interface(.caption)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(InterfaceScale.metric(20))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: max(160, availableSize.height - 220))
            .fixedSize(horizontal: false, vertical: true)
            .disabled(store.isWorking)
            GuildJoinRequestError(store: store)
        } else if store.error == nil {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity).frame(height: InterfaceScale.metric(140))
        } else {
            ContentUnavailableView("Unable to Load Application", systemImage: "exclamationmark.triangle",
                                   description: Text(store.error ?? ""))
                .frame(height: InterfaceScale.metric(160))
        }
        Divider()
        HStack {
            ModalGlassButton(symbol: "xmark", label: "Cancel") {
                if hasAnswers { confirmsDiscard = true } else { close() }
            }
            .disabled(store.isWorking)
            Spacer(minLength: InterfaceScale.metric(16))
            ModalGlassButton(symbol: "paperplane", label: "Submit", primary: true, isLoading: store.isWorking) {
                model.submitGuildJoinApplication()
            }
            .disabled(store.form?.fields.allSatisfy(\.isSatisfied) != true || store.isWorking)
            .keyboardShortcut(.defaultAction)
        }
        .padding(InterfaceScale.metric(12))
    }

    @ViewBuilder private var welcome: some View {
        StatusCard(symbol: "checkmark", tint: .green, iconURL: iconURL, guildName: guildName,
                   title: "Welcome to \(guildName)!", detail: "You’re all set. Jump in and say hi.")
        Divider()
        HStack {
            Spacer()
            ModalGlassButton(symbol: "arrow.right", label: "Go to Server", primary: true) { close() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(InterfaceScale.metric(12))
    }
}

/// An application's status, shown in place of the workspace while its pending server is selected, as in Discord.
struct GuildJoinRequestPage: View {
    let model: AppModel
    let guildID: GuildID
    @State private var confirmsWithdraw = false

    private var store: GuildJoinRequestStore { model.guildJoinRequests }
    private var request: GuildJoinRequest? { store.requests[guildID] }
    private var guildName: String { model.joinRequestGuildName(guildID) }

    var body: some View {
        let rejected = request?.status == .rejected
        ScrollView(.vertical) {
            VStack(spacing: InterfaceScale.metric(16)) {
                VStack(spacing: 0) {
                    StatusCard(symbol: rejected ? "xmark" : "hourglass", tint: rejected ? .red : .gray,
                               iconURL: model.joinRequestGuildIconURL(guildID), guildName: guildName,
                               title: rejected ? "Your application to join \(guildName) has been denied."
                                               : "Your application to join \(guildName) is awaiting review!",
                               detail: rejected ? request?.rejectionReason.map { "Reason: \($0)" }
                                                : "You’ll get notified when there’s an update.")
                    HStack(spacing: InterfaceScale.metric(8)) {
                        if rejected {
                            ModalGlassButton(symbol: "arrow.clockwise", label: "Reapply", fillsWidth: true) {
                                model.reapplyToGuild(guildID)
                            }
                        }
                        ModalGlassButton(symbol: "arrow.uturn.backward", label: "Withdraw", primary: true, destructive: true,
                                         fillsWidth: true) { confirmsWithdraw = true }
                    }
                    .disabled(store.isWorking)
                    .padding([.horizontal, .bottom], InterfaceScale.metric(24))
                    GuildJoinRequestError(store: store)
                }
                .frame(maxWidth: InterfaceScale.metric(440))
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: InterfaceScale.metric(24)))
                HStack(spacing: InterfaceScale.metric(20)) {
                    Button(store.showsAnswers ? "Hide Application" : "View Application") {
                        model.toggleGuildJoinRequestAnswers(guildID)
                    }
                    if let channelID = request?.interviewChannelID {
                        Button("Open Interview") { model.navigate(to: channelID) }
                    }
                }
                .buttonStyle(.link)
                if store.showsAnswers { answers }
            }
            .padding(InterfaceScale.metric(32))
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .animation(.snappy(duration: 0.2), value: store.showsAnswers)
        .alert("Are you sure?", isPresented: $confirmsWithdraw) {
            Button("Yes", role: .destructive) { model.withdrawGuildJoinRequest(guildID) }
            Button("Never Mind", role: .cancel) {}
        } message: {
            Text("Are you sure you want to withdraw your application from \(guildName)?")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Application to \(guildName)")
    }

    @ViewBuilder private var answers: some View {
        if let fields = request.flatMap({ store.answers[$0.id] }) {
            VStack(alignment: .leading, spacing: InterfaceScale.metric(16)) {
                ForEach(fields.indices, id: \.self) { GuildJoinApplicationAnswerRow(field: fields[$0]) }
            }
            .frame(maxWidth: InterfaceScale.metric(440), alignment: .leading)
        } else if store.isWorking {
            ProgressView().controlSize(.small)
        }
    }
}

/// The failed action's explanation, under the controls that started it.
private struct GuildJoinRequestError: View {
    let store: GuildJoinRequestStore

    var body: some View {
        if let error = store.error {
            Text(error).font(.interface(.callout)).foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, InterfaceScale.metric(20)).padding(.bottom, InterfaceScale.metric(12))
        }
    }
}

private struct StatusCard: View {
    let symbol: String
    let tint: Color
    let iconURL: URL?
    let guildName: String
    let title: String
    let detail: String?

    var body: some View {
        VStack(spacing: InterfaceScale.metric(12)) {
            GuildIconView(name: guildName, iconURL: iconURL, size: InterfaceScale.metric(64), cornerRadius: InterfaceScale.metric(18))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: symbol)
                        .font(.interfaceSystem(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: InterfaceScale.metric(24), height: InterfaceScale.metric(24))
                        .background(tint, in: Circle())
                        .overlay { Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 3) }
                        .offset(x: InterfaceScale.metric(6), y: InterfaceScale.metric(6))
                }
                .accessibilityHidden(true)
            Text(title).font(.interface(.title3).weight(.semibold)).multilineTextAlignment(.center)
            if let detail {
                Text(detail).font(.interface(.callout)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(InterfaceScale.metric(24))
        .frame(maxWidth: .infinity)
    }
}

private struct GuildJoinApplicationFieldEditor: View {
    @Binding var field: GuildJoinApplicationField

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(8)) {
            GuildJoinApplicationFieldLabel(field: field)
            switch field.kind {
            case .shortAnswer:
                TextField(field.placeholder ?? "Enter your answer", text: text)
                    .textFieldStyle(.plain)
                    .padding(InterfaceScale.metric(10))
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: InterfaceScale.metric(10)))
            case .paragraph:
                TextEditor(text: text)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: InterfaceScale.metric(88))
                    .padding(InterfaceScale.metric(6))
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: InterfaceScale.metric(10)))
                    .overlay(alignment: .topLeading) {
                        if text.wrappedValue.isEmpty {
                            Text(field.placeholder ?? "Enter your answer").foregroundStyle(.tertiary)
                                .padding(InterfaceScale.metric(11)).allowsHitTesting(false)
                        }
                    }
            case .multipleChoice(let choices):
                VStack(alignment: .leading, spacing: InterfaceScale.metric(6)) {
                    ForEach(choices.indices, id: \.self) { index in
                        Button { field.answer = .choice(index) } label: {
                            Label(choices[index], systemImage: field.answer == .choice(index) ? "largecircle.fill.circle" : "circle")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(field.answer == .choice(index) ? .isSelected : [])
                    }
                }
            case .terms(let rules):
                VStack(alignment: .leading, spacing: InterfaceScale.metric(10)) {
                    ForEach(rules.indices, id: \.self) { index in
                        Text("\(index + 1). \(rules[index])").fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(InterfaceScale.metric(12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: InterfaceScale.metric(10)))
                Toggle("I have read and agree to the rules", isOn: Binding(
                    get: { field.answer == .agreed(true) },
                    set: { field.answer = $0 ? .agreed(true) : nil }
                ))
                .toggleStyle(.checkbox)
            case .unsupported:
                Text("Answer this question in Discord.").foregroundStyle(.secondary)
            }
            counter
        }
        .font(.interface(.body))
    }

    /// An emptied field is unanswered again.
    private var text: Binding<String> {
        Binding(
            get: { if case .text(let value) = field.answer { value } else { "" } },
            set: { field.answer = $0.isEmpty ? nil : .text($0) }
        )
    }

    /// Discord limits answers; past the limit the count turns red and Submit stays disabled.
    @ViewBuilder private var counter: some View {
        if let limit = field.characterLimit, text.wrappedValue.count > limit * 4 / 5 {
            let count = text.wrappedValue.count
            Text("\(count)/\(limit)")
                .font(.interface(.caption).monospacedDigit())
                .foregroundStyle(count > limit ? .red : .secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

private struct GuildJoinApplicationFieldLabel: View {
    let field: GuildJoinApplicationField

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(2)) {
            HStack(alignment: .firstTextBaseline) {
                Text(field.kind.isTerms ? "Agree to rules" : field.label).font(.interface(.headline))
                if !field.isRequired { Text("Optional").font(.interface(.caption)).foregroundStyle(.secondary) }
            }
            if let description = field.description, !description.isEmpty {
                Text(description).font(.interface(.callout)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct GuildJoinApplicationAnswerRow: View {
    let field: GuildJoinApplicationField

    var body: some View {
        if case .terms = field.kind {
            Label(field.answer == .agreed(true) ? "Agreed to Rules" : "Did not agree to the rules",
                  systemImage: field.answer == .agreed(true) ? "checkmark.circle.fill" : "circle")
                .symbolRenderingMode(.multicolor)
                .padding(InterfaceScale.metric(12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: InterfaceScale.metric(10)))
        } else {
            VStack(alignment: .leading, spacing: InterfaceScale.metric(6)) {
                Text(field.label).font(.interface(.callout).weight(.medium)).foregroundStyle(.secondary)
                Text(answerText ?? "No answer").foregroundStyle(answerText == nil ? .tertiary : .primary)
                    .textSelection(.enabled)
                    .padding(InterfaceScale.metric(12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: InterfaceScale.metric(10)))
            }
        }
    }

    private var answerText: String? {
        switch (field.kind, field.answer) {
        case (_, .text(let text)?): text
        case (.multipleChoice(let choices), .choice(let index)?): choices.indices.contains(index) ? choices[index] : nil
        default: nil
        }
    }
}

private extension GuildJoinApplicationField.Kind {
    var isTerms: Bool { if case .terms = self { true } else { false } }
}
