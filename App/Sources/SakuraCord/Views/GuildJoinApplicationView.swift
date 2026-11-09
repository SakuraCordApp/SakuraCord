import SakuraCordModels
import SwiftUI

/// SakuraCord's snappy motion, off under macOS Reduce Motion or the app's own animation settings.
@MainActor private func snappyMotion(_ duration: Double, in category: AppMotionCategory? = nil) -> Animation? {
    (category.map(AppMotionPolicy.animates) ?? AppMotionPolicy.animatesUncategorized) ? .snappy(duration: duration) : nil
}

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
        // Explicit transactions also resize the modal panel, which sizes to this content.
        .animation(snappyMotion(0.25, in: .overlays), value: store.form != nil)
        .animation(snappyMotion(0.25, in: .overlays), value: store.error)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(modal.kind == .form ? "Application to \(guildName)" : "Welcome to \(guildName)")
    }

    private func close() {
        dismiss?(allowsDisabled: true)
    }

    /// Cancel and Escape both ask before discarding typed answers.
    private func cancel() {
        guard !store.isWorking else { return }
        if hasAnswers { confirmsDiscard = true } else { close() }
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
        .padding(.horizontal, InterfaceScale.metric(18)).padding(.vertical, InterfaceScale.metric(16))
        Divider()
        if let form = store.form {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: InterfaceScale.metric(20)) {
                    // A screened member is already in the server and nobody reviews the answers; Discord words it so.
                    let isScreening = model.serverRailGuildsByID[modal.guildID] != nil
                    VStack(alignment: .leading, spacing: InterfaceScale.metric(4)) {
                        Text(isScreening ? "Before you can talk here…" : "Answer a few questions to join \(guildName)")
                            .font(.interface(.title3).weight(.semibold))
                        Text(isScreening ? "You’ll need to complete the required steps below."
                                         : "The server admin will get back to you shortly after you submit.")
                            .font(.interface(.callout)).foregroundStyle(.secondary)
                    }
                    ForEach(form.fields.indices, id: \.self) { index in
                        GuildJoinApplicationFieldEditor(field: Binding(
                            get: { store.form?.fields[index] ?? form.fields[index] },
                            set: { store.form?.fields[index] = $0 }
                        ))
                    }
                    if !isScreening {
                        Text("""
                        Make sure you have not entered your password or any other sensitive information. \
                        By applying, you give the server admins permission to message you regarding your application.
                        """)
                            .font(.interface(.caption)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, InterfaceScale.metric(18)).padding(.vertical, InterfaceScale.metric(16))
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
            ModalGlassButton(symbol: "xmark", label: "Cancel", action: cancel)
            .disabled(store.isWorking)
            Spacer(minLength: InterfaceScale.metric(16))
            ModalGlassButton(symbol: "paperplane", label: "Submit", primary: true, isLoading: store.isWorking) {
                model.submitGuildJoinApplication()
            }
            .disabled(store.form?.fields.allSatisfy(\.isSatisfied) != true || store.isWorking)
            .keyboardShortcut(.defaultAction)
        }
        .padding(InterfaceScale.metric(12))
        .onAppear { dismiss?.escapeAction = cancel }
        .onDisappear { dismiss?.escapeAction = nil }
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
    private enum Action { case reapply, withdraw, answers }

    let model: AppModel
    let guildID: GuildID
    @State private var confirmsWithdraw = false
    @State private var action: Action?

    /// Buttons keep their 40-point capsules concentric with the card by sharing this inset.
    private let cardInset = InterfaceScale.metric(16)
    private var cardRadius: CGFloat { InterfaceScale.metric(20) + cardInset }
    private var motion: Animation? { snappyMotion(0.25) }

    private var store: GuildJoinRequestStore { model.guildJoinRequests }
    private var request: GuildJoinRequest? { store.requests[guildID] }
    private var guildName: String { model.joinRequestGuildName(guildID) }
    private var status: GuildJoinRequest.Status? { request?.status }

    var body: some View {
        let card = RoundedRectangle(cornerRadius: cardRadius)
        ScrollView(.vertical) {
            VStack(spacing: InterfaceScale.metric(16)) {
                VStack(spacing: 0) {
                    statusCard
                    GlassEffectContainer(spacing: InterfaceScale.metric(8)) {
                        HStack(spacing: InterfaceScale.metric(8)) {
                            switch status {
                            case .started?:
                                ModalGlassButton(symbol: "list.bullet", label: "Open Application", fillsWidth: true) {
                                    model.openGuildJoinApplication(guildID)
                                }
                            case .rejected?:
                                ModalGlassButton(symbol: "arrow.clockwise", label: "Reapply", isLoading: isRunning(.reapply),
                                                 fillsWidth: true) {
                                    action = .reapply
                                    model.reapplyToGuild(guildID)
                                }
                            default:
                                EmptyView()
                            }
                            ModalGlassButton(symbol: status == .started ? "trash" : "arrow.uturn.backward",
                                             label: status == .started ? "Discard Application" : "Withdraw",
                                             primary: true, destructive: true,
                                             isLoading: isRunning(.withdraw), fillsWidth: true) { confirmsWithdraw = true }
                        }
                    }
                    .disabled(store.isWorking)
                    .padding([.horizontal, .bottom], cardInset)
                    GuildJoinRequestError(store: store)
                }
                .frame(maxWidth: InterfaceScale.metric(440))
                .background(.background.opacity(0.88), in: card)
                .overlay { card.stroke(.primary.opacity(0.06)) }
                .containerShape(card)
                // An unsubmitted application has no answers on Discord yet.
                if status != .started {
                    GlassEffectContainer(spacing: InterfaceScale.metric(8)) {
                        HStack(spacing: InterfaceScale.metric(8)) {
                            ModalGlassButton(symbol: store.showsAnswers ? "eye.slash" : "eye",
                                             label: store.showsAnswers ? "Hide Application" : "View Application",
                                             isLoading: isRunning(.answers),
                                             height: 32) {
                                action = .answers
                                model.toggleGuildJoinRequestAnswers(guildID)
                            }
                            if let channelID = request?.interviewChannelID {
                                ModalGlassButton(symbol: "bubble.left.and.bubble.right", label: "Open Interview", height: 32) {
                                    model.navigate(to: channelID)
                                }
                            }
                        }
                    }
                    .disabled(store.isWorking)
                    if store.showsAnswers { answers }
                }
            }
            .padding(InterfaceScale.metric(32))
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        // Discord centres the status in the window; a page taller than it scrolls from the top.
        .defaultScrollAnchor(.center, for: .alignment)
        .background { SakuraCordSignInBackdrop().ignoresSafeArea(edges: .top) }
        .tint(SakuraCordAccentColor.color)
        .animation(motion, value: store.showsAnswers)
        .animation(motion, value: status)
        .animation(motion, value: request?.interviewChannelID)
        .animation(motion, value: store.error)
        .animation(motion, value: answersLoaded)
        .alert("Are you sure?", isPresented: $confirmsWithdraw) {
            Button("Yes", role: .destructive) {
                action = .withdraw
                model.withdrawGuildJoinRequest(guildID)
            }
            Button("Never Mind", role: .cancel) {}
        } message: {
            Text(status == .started ? "If you discard, you can start a new application from an invite link."
                                    : "Are you sure you want to withdraw your application from \(guildName)?")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Application to \(guildName)")
    }

    @ViewBuilder private var statusCard: some View {
        let iconURL = model.joinRequestGuildIconURL(guildID)
        switch status {
        case .started?:
            StatusCard(symbol: status.symbolName, tint: .gray, iconURL: iconURL, guildName: guildName,
                       title: "Submit your application to join \(guildName).", detail: nil)
        case .rejected?:
            StatusCard(symbol: status.symbolName, tint: .red, iconURL: iconURL, guildName: guildName,
                       title: "Your application to join \(guildName) has been denied.",
                       detail: request?.rejectionReason.map { "Reason: \($0)" })
        default:
            StatusCard(symbol: status.symbolName, tint: .gray, iconURL: iconURL, guildName: guildName,
                       title: "Your application to join \(guildName) is awaiting review!",
                       detail: "You’ll get notified when there’s an update.")
        }
    }

    private func isRunning(_ action: Action) -> Bool { store.isWorking && self.action == action }

    private var answersLoaded: Bool { request.flatMap { store.answers[$0.id] } != nil }

    @ViewBuilder private var answers: some View {
        if let fields = request.flatMap({ store.answers[$0.id] }) {
            VStack(alignment: .leading, spacing: InterfaceScale.metric(16)) {
                ForEach(fields.indices, id: \.self) { GuildJoinApplicationAnswerRow(field: fields[$0]) }
            }
            .frame(maxWidth: InterfaceScale.metric(440), alignment: .leading)
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
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
                .clipShape(RoundedRectangle(cornerRadius: InterfaceScale.metric(18), style: .continuous))
                .modifier(ApplicationStatusBadge(symbol: symbol, tint: tint, diameter: 24, offset: 6))
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
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(8)) {
            GuildJoinApplicationFieldLabel(field: field)
            switch field.kind {
            case .shortAnswer:
                textField(TextField(field.placeholder ?? "Enter your answer", text: text).accessibilityLabel(field.label))
            case .paragraph:
                // A text view, so Return starts a new line as in Discord's paragraph answers.
                textField(ZStack(alignment: .topLeading) {
                    if text.wrappedValue.isEmpty {
                        Text(field.placeholder ?? "Enter your answer")
                            .foregroundStyle(.tertiary)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    TextEditor(text: text)
                        .textEditorStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: InterfaceScale.metric(54), maxHeight: InterfaceScale.metric(180))
                        .fixedSize(horizontal: false, vertical: true)
                        // Aligns typed text with the placeholder despite the text view's line padding.
                        .padding(.horizontal, -InterfaceScale.metric(5))
                        .accessibilityLabel(field.label)
                })
            case .multipleChoice(let choices):
                VStack(spacing: InterfaceScale.metric(4)) {
                    ForEach(choices.indices, id: \.self) { index in
                        let isSelected = field.answer == .choice(index)
                        Button { field.answer = .choice(index) } label: {
                            InteractionModalChoiceRow(label: choices[index], symbol: isSelected ? "largecircle.fill.circle" : "circle",
                                                      isSelected: isSelected)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
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
                .modifier(InteractionModalFieldBackground())
                let agreed = field.answer == .agreed(true)
                Button { field.answer = agreed ? nil : .agreed(true) } label: {
                    InteractionModalChoiceRow(label: "I have read and agree to the rules",
                                              symbol: agreed ? "checkmark.square.fill" : "square", isSelected: agreed)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(agreed ? [.isButton, .isSelected] : .isButton)
            case .unsupported:
                Text("Answer this question in Discord.").foregroundStyle(.secondary)
            }
            counter
        }
        .font(.interface(.body))
        .animation(snappyMotion(0.2, in: .overlays), value: showsCounter)
    }

    private func textField(_ field: some View) -> some View {
        field
            .textFieldStyle(.plain)
            .tint(SakuraCordAccentColor.color)
            .focused($isFocused)
            .padding(.horizontal, InterfaceScale.metric(11)).padding(.vertical, InterfaceScale.metric(9))
            .modifier(InteractionModalFieldBackground(isFocused: isFocused) { isFocused = true })
    }

    /// An emptied field is unanswered again.
    private var text: Binding<String> {
        Binding(
            get: { if case .text(let value) = field.answer { value } else { "" } },
            set: { newValue in
                let previous = if case .text(let value) = field.answer { value } else { "" }
                field.answer = newValue.isEmpty ? nil : .text(field.limited(newValue, replacing: previous))
            }
        )
    }

    private var showsCounter: Bool {
        field.characterLimit.map { text.wrappedValue.utf16.count > $0 * 4 / 5 } ?? false
    }

    /// The remaining room as the answer nears Discord's limit, which input cannot pass.
    @ViewBuilder private var counter: some View {
        if showsCounter, let limit = field.characterLimit {
            let count = text.wrappedValue.utf16.count
            Text("\(count)/\(limit)")
                .font(.interface(.caption).monospacedDigit())
                .foregroundStyle(count >= limit ? .orange : .secondary)
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
                .modifier(InteractionModalFieldBackground())
        } else {
            VStack(alignment: .leading, spacing: InterfaceScale.metric(6)) {
                Text(field.label).font(.interface(.callout).weight(.medium)).foregroundStyle(.secondary)
                Text(answerText ?? "No answer").foregroundStyle(answerText == nil ? .tertiary : .primary)
                    .textSelection(.enabled)
                    .padding(InterfaceScale.metric(12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(InteractionModalFieldBackground())
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

extension GuildJoinRequest.Status {
    /// Discord's wording for each state, on the rail's hover label and the status page's sidebar.
    var membershipDescription: String {
        switch self {
        case .started: "Membership Incomplete"
        case .rejected: "Membership Rejected"
        default: "Membership In Review"
        }
    }
}

extension GuildJoinRequest.Status? {
    /// The glyph that marks an application's state on its page, its rail badge and the toolbar.
    var symbolName: String {
        switch self {
        case .started?: "list.bullet"
        case .rejected?: "xmark"
        default: "hourglass"
        }
    }
}

private extension GuildJoinApplicationField.Kind {
    var isTerms: Bool { if case .terms = self { true } else { false } }
}

/// The channel list's place while an application is selected: the server applied to, as the application form
/// describes it, and where the application stands.
struct GuildJoinRequestSidebar: View {
    let model: AppModel
    let guildID: GuildID
    let bottomContentInset: CGFloat

    private var store: GuildJoinRequestStore { model.guildJoinRequests }

    var body: some View {
        let preview = store.previews[guildID]
        let request = store.requests[guildID]
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: InterfaceScale.metric(16)) {
                HStack(spacing: InterfaceScale.metric(12)) {
                    GuildIconView(name: model.joinRequestGuildName(guildID), iconURL: model.joinRequestGuildIconURL(guildID),
                                  size: InterfaceScale.metric(52), cornerRadius: InterfaceScale.metric(15))
                    VStack(alignment: .leading, spacing: InterfaceScale.metric(4)) {
                        Text(model.joinRequestGuildName(guildID))
                            .font(.interface(.headline))
                            .lineLimit(2)
                        if let preview, let members = preview.memberCount {
                            // A narrow sidebar stacks the counts rather than breaking their words.
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: InterfaceScale.metric(10)) { counts(preview, members: members) }
                                VStack(alignment: .leading, spacing: InterfaceScale.metric(2)) { counts(preview, members: members) }
                            }
                            .transition(.opacity)
                        }
                    }
                }
                if let description = preview?.description, !description.isEmpty {
                    VStack(alignment: .leading, spacing: InterfaceScale.metric(6)) {
                        Text("About").font(.interface(.subheadline).weight(.semibold)).foregroundStyle(.secondary)
                        Text(description).font(.interface(.callout)).textSelection(.enabled)
                    }
                    .transition(.opacity)
                }
                if let request {
                    Divider()
                    VStack(alignment: .leading, spacing: InterfaceScale.metric(4)) {
                        Label(request.status.membershipDescription, systemImage: Optional(request.status).symbolName)
                            .font(.interface(.callout).weight(.semibold))
                            .contentTransition(.symbolEffect(.replace))
                        Text("Started \(request.id.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.interface(.caption))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(InterfaceScale.metric(16))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentMargins(.bottom, bottomContentInset, for: .scrollContent)
        .animation(model.animates(.sidebar) ? .snappy(duration: 0.25) : nil, value: preview == nil)
        .animation(model.animates(.sidebar) ? .snappy(duration: 0.25) : nil, value: request?.status)
        .task(id: guildID) { await model.loadGuildJoinRequestPreview(guildID) }
    }

    @ViewBuilder private func counts(_ preview: GuildJoinApplicationForm, members: Int) -> some View {
        if let online = preview.onlineCount { count(online, "Online", color: .green) }
        count(members, members == 1 ? "Member" : "Members", color: .secondary)
    }

    private func count(_ value: Int, _ label: String, color: Color) -> some View {
        HStack(spacing: InterfaceScale.metric(4)) {
            Circle().fill(color).frame(width: InterfaceScale.metric(7), height: InterfaceScale.metric(7))
            Text("\(value.formatted()) \(label)").font(.interface(.caption)).foregroundStyle(.secondary)
        }
        .fixedSize()
    }
}
