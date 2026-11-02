import SwiftUI

enum IssueReportFocus: Hashable {
    case title
    case field(String)
}

private extension IssueReportStore {
    func binding(_ id: String) -> Binding<String> {
        Binding(get: { self.value(id) }, set: { self.setValue($0, for: id) })
    }
}

// MARK: Describe

struct IssueReportDescribeStep: View {
    let model: AppModel
    @FocusState private var focus: IssueReportFocus?

    private var store: IssueReportStore { model.issueReports }

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(8)) {
            IssueReportKindPicker(kind: store.kind) { kind in
                withAnimation(.snappy(duration: 0.3)) { store.switchKind(to: kind) }
            }
            if store.installedVersion == nil {
                IssueReportVersionNotice(store: store)
                    .transition(.opacity)
            }
            titleField
            ForEach(store.fields(on: 1)) { field in
                IssueReportFieldView(store: store, privacy: model.uploadPrivacyPreparation, field: field, focus: $focus)
            }
            // Below the fields, so matches never move the field being typed in.
            if !store.similar.isEmpty {
                IssueReportSimilarCard(model: model)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        .animation(.snappy(duration: 0.3), value: store.similar)
        .task {
            await Task.yield()
            if store.value("title").isEmpty { focus = .title }
        }
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(6)) {
            IssueReportFieldHeader(
                label: "Title", count: store.value("title").count,
                maximum: IssueReportForm.titleLengthRange.upperBound
            )
            TextField(
                store.definition?.titlePlaceholder ?? "",
                text: store.binding("title"),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.interfaceSystem(size: 18, weight: .medium))
            .lineLimit(1 ... 3)
            .tint(SakuraCordAccentColor.color)
            .focused($focus, equals: .title)
            .onSubmit { focus = store.primaryField.map { .field($0.id) } }
            .accessibilityLabel("Title")
        }
        .issueReportRow(highlighted: focus == .title) { focus = .title }
    }
}

private struct IssueReportKindPicker: View {
    let kind: IssueReportKind
    let select: (IssueReportKind) -> Void
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: InterfaceScale.metric(6)) {
            HStack(spacing: InterfaceScale.metric(6)) {
                ForEach(IssueReportKind.allCases, id: \.self) { option in
                    Button { select(option) } label: {
                        HStack(spacing: InterfaceScale.metric(6)) {
                            Image(systemName: IssueReportKindBadge.symbol(option))
                                .frame(width: InterfaceScale.metric(18), height: InterfaceScale.metric(18))
                            Text(option == .bug ? "Bug" : "Feature")
                        }
                            .font(.interface(.callout).weight(.semibold))
                            .foregroundStyle(option == kind ? .white : .primary)
                            .frame(maxWidth: .infinity, minHeight: InterfaceScale.metric(34))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(
                        option == kind ? .regular.tint(SakuraCordAccentColor.color).interactive() : .regular.interactive(),
                        in: Capsule()
                    )
                    .glassEffectID(option, in: glass)
                    .accessibilityAddTraits(option == kind ? [.isSelected] : [])
                }
            }
        }
        .padding(.bottom, InterfaceScale.metric(2))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Report type")
    }
}

/// Shown when this build isn't the latest nightly or regular release.
private struct IssueReportVersionNotice: View {
    let store: IssueReportStore

    var body: some View {
        HStack(alignment: .top, spacing: InterfaceScale.metric(12)) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.interfaceSystem(size: 15, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: InterfaceScale.metric(32), height: InterfaceScale.metric(32))
                .glassEffect(.regular.tint(.orange.opacity(0.25)), in: Circle())
            VStack(alignment: .leading, spacing: InterfaceScale.metric(4)) {
                Text("Update and retest first").font(.interface(.callout).weight(.semibold))
                Text(message).font(.interface(.caption)).foregroundStyle(.secondary)
                HStack(spacing: InterfaceScale.metric(8)) {
                    Button("Check for Updates") {
                        AppDelegate.current?.updateController.checkForUpdates()
                    }
                    Menu(store.selectedVersion.map { "Retested on \($0)" } ?? "I Retested On…") {
                        ForEach(store.form?.versions ?? [], id: \.self) { version in
                            Button(version) { store.setValue(version, for: "version") }
                        }
                    }
                    .fixedSize()
                }
                .controlSize(.small)
                .padding(.top, InterfaceScale.metric(2))
            }
            Spacer(minLength: 0)
        }
        .issueReportRow(padding: 12)
    }

    private var message: String {
        let versions = ListFormatter.localizedString(byJoining: store.form?.versions ?? [])
        let installed = store.systemInfo.appVersion.map { "This is \($0). " } ?? ""
        return "\(installed)Reports are accepted for \(versions)."
    }
}

private struct IssueReportSimilarCard: View {
    let model: AppModel
    @State private var reportToFollow: Int?

    private var store: IssueReportStore { model.issueReports }

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(6)) {
            Label("Already reported?", systemImage: "square.on.square.dashed")
                .font(.interface(.callout).weight(.semibold))
                .padding(.horizontal, InterfaceScale.metric(6))
            Text("Follow a match instead and you’ll get the same updates.")
                .font(.interface(.caption))
                .foregroundStyle(.secondary)
                .padding(.horizontal, InterfaceScale.metric(6))
                .padding(.bottom, InterfaceScale.metric(2))
            ForEach(store.similar) { report in
                HStack(spacing: InterfaceScale.metric(10)) {
                    VStack(alignment: .leading, spacing: InterfaceScale.metric(2)) {
                        Text("#\(report.number) · \(report.title)").lineLimit(2)
                        Text(details(report)).font(.interface(.caption)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: InterfaceScale.metric(8))
                    HoverActionButton(systemImage: "arrow.up.right", help: "Open on the Tracker", diameter: InterfaceScale.metric(28)) {
                        NSWorkspace.shared.open(report.trackerUrl)
                    }
                    if report.open {
                        Button("That’s Mine") { reportToFollow = report.number }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                            .disabled(store.isSubmitting)
                    }
                }
                .padding(.horizontal, InterfaceScale.metric(10))
                .padding(.vertical, InterfaceScale.metric(8))
                .background(
                    .background.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: IssueReportMetrics.controlRadius, style: .continuous)
                )
            }
        }
        .padding(InterfaceScale.metric(8))
        .padding(.top, InterfaceScale.metric(4))
        .background(
            SakuraCordAccentColor.color.opacity(0.1),
            in: RoundedRectangle(cornerRadius: IssueReportMetrics.rowRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: IssueReportMetrics.rowRadius, style: .continuous)
                .strokeBorder(SakuraCordAccentColor.color.opacity(0.3))
        }
        .confirmationDialog(
            "Follow this report?",
            isPresented: Binding(get: { reportToFollow != nil }, set: { if !$0 { reportToFollow = nil } }),
            titleVisibility: .visible,
            presenting: reportToFollow
        ) { number in
            Button("Follow #\(number) and Share Details") { model.followExistingIssueReport(number) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Your description and steps will be posted publicly with your Discord identity. You’ll receive updates on this report.")
        }
    }

    private func details(_ report: IssueReportSimilar) -> String {
        ([report.statusLabel] + (report.votes > 0 ? ["👍 \(report.votes)"] : []) + [report.resolution].compactMap(\.self))
            .joined(separator: " · ")
    }
}

/// Renders one schema field by kind.
private struct IssueReportFieldView: View {
    let store: IssueReportStore
    let privacy: UploadPrivacyPreparation
    let field: IssueReportField
    var focus: FocusState<IssueReportFocus?>.Binding

    var body: some View {
        switch field.kind {
        case .paragraph, .short:
            IssueReportTextArea(field: field, text: store.binding(field.id), focus: focus, focusValue: .field(field.id))
        case .choice:
            IssueReportChoiceGroup(field: field, selection: store.binding(field.id))
        case .area:
            IssueReportAreaPicker(field: field, areas: store.form?.meta.areas ?? [], selection: store.binding(field.id))
        case .files:
            IssueReportAttachmentTray(
                field: field,
                attachments: store.draft.attachments,
                remainingSlots: IssueReportHubClient.maximumFileCount - store.uploadCount,
                add: add,
                remove: { attachment in store.draft.attachments.removeAll { $0.id == attachment.id } }
            )
        case .version, .unsupported:
            EmptyView()
        }
    }

    private func add(_ urls: [URL]) {
        Task { await store.addAttachments(urls, using: privacy) }
    }
}

// MARK: Details

struct IssueReportDetailsStep: View {
    let model: AppModel
    @FocusState private var focus: IssueReportFocus?

    private var store: IssueReportStore { model.issueReports }

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(8)) {
            ForEach(store.fields(on: 2)) { field in
                IssueReportFieldView(store: store, privacy: model.uploadPrivacyPreparation, field: field, focus: $focus)
                if field.kind == .files, store.kind == .bug {
                    IssueReportDiagnosticsCard(store: store)
                }
            }
            if store.kind == .bug, store.field(ofKind: .files)?.page != 2 {
                IssueReportDiagnosticsCard(store: store)
            }
        }
    }
}

/// Information SakuraCord can include without the person exporting anything.
private struct IssueReportDiagnosticsCard: View {
    let store: IssueReportStore
    @State private var panicSave = IssueReportDiagnostics.latestPanicSave()
    @State private var apiLogEntries = IssueReportDiagnostics.retainedAPILogEntryCount

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(4)) {
            HStack(spacing: InterfaceScale.metric(6)) {
                Text("Diagnostics").font(.interface(.callout).weight(.semibold))
                Spacer()
                Label("Filled in by SakuraCord", systemImage: "sparkles")
                    .font(.interface(.caption))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, InterfaceScale.metric(8))
            .padding(.top, InterfaceScale.metric(6))
            .padding(.bottom, InterfaceScale.metric(2))
            IssueReportToggleRow(
                symbol: "desktopcomputer",
                title: "System information",
                detail: [store.systemInfo.macOS, store.systemInfo.mac].compactMap(\.self).joined(separator: " · "),
                isOn: draft(\.includesSystemInfo)
            )
            IssueReportToggleRow(
                symbol: "doc.text.magnifyingglass",
                title: "Discord API log",
                detail: apiLogEntries > 0
                    ? "\(apiLogEntries.formatted()) recent events, sanitised"
                    : "Nothing recorded yet",
                isOn: draft(\.includesAPILog),
                isAvailable: apiLogEntries > 0
            )
            IssueReportToggleRow(
                symbol: "exclamationmark.octagon",
                title: "Latest panic save",
                detail: panicSaveDetail,
                isOn: draft(\.includesPanicSave),
                isAvailable: panicSave != nil
            )
            Text("Diagnostics leave out message text, tokens, IDs, and URLs. Everything you attach is public.")
                .font(.interface(.caption))
                .foregroundStyle(.secondary)
                .padding(.horizontal, InterfaceScale.metric(8))
                .padding(.vertical, InterfaceScale.metric(6))
        }
        .issueReportRow(padding: 8)
        .onAppear {
            panicSave = IssueReportDiagnostics.latestPanicSave()
            apiLogEntries = IssueReportDiagnostics.retainedAPILogEntryCount
        }
    }

    private var panicSaveDetail: String {
        if let panicSave {
            return "Saved \(panicSave.savedAt.formatted(.relative(presentation: .named)))"
        }
        return IssueReportDiagnostics.panicSaveIsEnabled ? "None saved on this Mac" : "Panic save is turned off"
    }

    private func draft(_ keyPath: WritableKeyPath<IssueReportStore.Draft, Bool>) -> Binding<Bool> {
        Binding(
            get: { store.draft[keyPath: keyPath] },
            set: { value in
                if value, !store.draft[keyPath: keyPath], keyPath != \.includesSystemInfo,
                   store.uploadCount >= IssueReportHubClient.maximumFileCount
                {
                    store.error = "Attach at most \(IssueReportHubClient.maximumFileCount) files, including diagnostics."
                    return
                }
                withAnimation(.snappy) { store.draft[keyPath: keyPath] = value }
            }
        )
    }
}

// MARK: Review

struct IssueReportReviewStep: View {
    let model: AppModel
    let navigate: (Bool, () -> Void) -> Void

    private var store: IssueReportStore { model.issueReports }

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(8)) {
            identity
            summary(step: .describe, rows: describeRows)
            summary(step: .details, rows: detailRows)
            Label(
                "Reports are public on GitHub, the tracker, and the SakuraCord Discord server.",
                systemImage: "globe"
            )
            .font(.interface(.caption))
            .foregroundStyle(.secondary)
            .padding(.horizontal, InterfaceScale.metric(14))
            .padding(.vertical, InterfaceScale.metric(4))
        }
    }

    private var identity: some View {
        HStack(spacing: InterfaceScale.metric(12)) {
            AvatarView(
                name: model.currentUser?.displayName ?? "",
                url: model.currentUser?.avatarURL,
                size: InterfaceScale.metric(40)
            )
            VStack(alignment: .leading, spacing: 1) {
                Text("Filing as \(model.currentUser?.displayName ?? "you")").font(.interface(.callout).weight(.semibold))
                Text("Discord shares your username and ID with the SakuraCord tracker. Your Discord account token stays on this Mac.")
                    .font(.interface(.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: InterfaceScale.metric(8))
            Image(systemName: "checkmark.shield.fill")
                .font(.interfaceSystem(size: 20))
                .foregroundStyle(SakuraCordAccentColor.color)
                .symbolEffect(.bounce, value: store.step)
                .accessibilityHidden(true)
        }
        .issueReportRow(padding: 12)
        .accessibilityElement(children: .combine)
    }

    private var describeRows: [(String, String)] {
        var rows = [("Title", store.value("title"))]
        for field in store.fields(on: 1) { if let value = display(field) { rows.append((field.label, value)) } }
        if let version = store.selectedVersion { rows.append(("SakuraCord version", version)) }
        return rows
    }

    private var detailRows: [(String, String)] {
        var rows: [(String, String)] = []
        for field in store.fields(on: 2) { if let value = display(field) { rows.append((field.label, value)) } }
        if store.kind == .bug {
            var included: [String] = []
            if store.draft.includesSystemInfo { included.append("system information") }
            if store.draft.includesAPILog { included.append("Discord API log") }
            if store.draft.includesPanicSave { included.append("latest panic save") }
            let list = ListFormatter.localizedString(byJoining: included)
            rows.append(("Diagnostics", included.isEmpty ? "None" : list.prefix(1).uppercased() + list.dropFirst()))
        }
        return rows
    }

    private func display(_ field: IssueReportField) -> String? {
        switch field.kind {
        case .files:
            let names = store.draft.attachments.map(\.name)
            return names.isEmpty ? nil : ListFormatter.localizedString(byJoining: names)
        case .choice:
            let value = store.value(field.id)
            return field.options?.first { $0.value == value }?.label
        case .area:
            let value = store.value(field.id)
            return store.form?.meta.areas.first { $0.id == value }.map { "\($0.emoji) \($0.label)" } ?? "Not sure"
        case .version, .unsupported:
            return nil
        case .paragraph, .short:
            let value = store.value(field.id).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
    }

    private func summary(step: IssueReportStore.Step, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(10)) {
            HStack {
                Text(step == .describe ? "Description" : "Details").font(.interface(.callout).weight(.semibold))
                Spacer()
                Button("Edit") { navigate(false) { store.go(to: step) } }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: InterfaceScale.metric(2)) {
                    Text(row.0).font(.interface(.caption)).foregroundStyle(.secondary)
                    Text(row.1).lineLimit(4).textSelection(.enabled)
                }
            }
        }
        .issueReportRow(padding: 14)
    }
}
