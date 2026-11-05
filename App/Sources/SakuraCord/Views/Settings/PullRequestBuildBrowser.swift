import SwiftUI

/// Window-modal browser for published PR builds. The 40-point header controls and
/// footer capsules sit 12 points inside the modal's 32-point container shape.
struct PullRequestBuildBrowser: View {
    @Environment(\.windowModalContext) private var dismiss
    @State private var store: PullRequestBuildStore
    @State private var confirmingBuild: PullRequestBuild?
    @FocusState private var searchIsFocused: Bool
    @ObservedObject var updateController: AppUpdateController
    let installedBuildID: String?
    let onInstall: (PullRequestBuild) -> Void

    init(
        isPreview: Bool = false,
        installedBuildID: String? = nil,
        updateController: AppUpdateController,
        onInstall: @escaping (PullRequestBuild) -> Void
    ) {
        _store = State(initialValue: PullRequestBuildStore(isPreview: isPreview))
        self.installedBuildID = installedBuildID
        self.updateController = updateController
        self.onInstall = onInstall
    }

    private var canConfirmInstallation: Bool {
        (store.isPreview || updateController.canSwitchBuilds) && store.selectedBuild != nil && !store.isLoading && store.error == nil
    }

    private var canInstall: Bool {
        canConfirmInstallation && !store.isPreview
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                sidebar.frame(width: InterfaceScale.metric(300))
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .windowModalSize(width: 880, height: 620)
        .task { await store.load() }
        .onChange(of: store.selectedPullRequest) { _, _ in
            store.selectedBuildID = nil
            confirmingBuild = nil
        }
        .onChange(of: store.selectedBuild?.id) { _, _ in confirmingBuild = nil }
        .alert("Install PR Build?", isPresented: Binding(
            get: { confirmingBuild != nil },
            set: { if !$0 { confirmingBuild = nil } }
        ), presenting: confirmingBuild) { build in
            Button("Cancel", role: .cancel) { confirmingBuild = nil }
            Button("Install and Restart") {
                guard canInstall, store.selectedBuild?.id == build.id else { return }
                onInstall(build)
                dismiss?()
            }
            .disabled(!canInstall || store.selectedBuild?.id != build.id)
        } message: { _ in
            Text("PR builds can be made by anyone and may contain bugs, issues, or malicious code. Please make sure that you understand the risks and have reviewed the code of this PR")
        }
        .onChange(of: store.search) { _, _ in
            if !store.pullRequests.contains(where: { $0.pullRequest == store.selectedPullRequest }) {
                store.selectedPullRequest = store.pullRequests.first?.pullRequest
            }
        }
        .animation(.snappy(duration: 0.22), value: store.selectedBuild?.id)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pull Request Builds")
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(16)) {
            HStack(spacing: InterfaceScale.metric(12)) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.interface(.title3).weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: InterfaceScale.metric(40), height: InterfaceScale.metric(40))
                    .glassEffect(.regular.tint(SakuraCordAccentColor.color), in: Circle())
                    .accessibilityHidden(true)
                Text("Pull Request Builds").font(.interface(.title2).weight(.semibold))
                Spacer()
                HStack(spacing: InterfaceScale.metric(8)) {
                    Button { Task { await store.load() } } label: {
                        HoverActionControlLabel(diameter: InterfaceScale.metric(40)) {
                            Image(systemName: "arrow.clockwise")
                                .font(.interfaceSystem(size: 14, weight: .semibold))
                                .symbolEffect(.rotate, options: .repeat(.continuous), isActive: store.isLoading)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isLoading)
                    .help("Refresh builds")
                    .accessibilityLabel("Refresh builds")
                    HoverCloseButton(help: "Close", accessibilityIdentifier: "pr-builds-close", diameter: InterfaceScale.metric(40)) { dismiss?() }
                }
            }
            PickerSearchHeader(text: $store.search, focus: { searchIsFocused = true }, input: {
                TextField("Search builds", text: $store.search)
                    .textFieldStyle(.plain)
                    .tint(SakuraCordAccentColor.color)
                    .focused($searchIsFocused)
                    .accessibilityIdentifier("pr-builds-search")
            })
            .background(.quaternary.opacity(0.5), in: ConcentricRectangle(cornerRadius: InterfaceScale.metric(12)))
            .task {
                await Task.yield()
                searchIsFocused = true
            }
        }
        .padding(InterfaceScale.metric(12))
    }

    // MARK: Sidebar

    @ViewBuilder
    private var sidebar: some View {
        if store.isLoading, store.builds.isEmpty {
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Loading builds")
        } else if store.pullRequests.isEmpty, store.error == nil {
            ContentUnavailableView(
                store.search.isEmpty ? "No Builds Yet" : "No Matching PRs",
                systemImage: "arrow.triangle.branch",
                description: Text(store.search.isEmpty ? "Published PR builds will appear here." : "Try a PR number, title, or commit.")
            )
        } else {
            ScrollView {
                VStack(spacing: InterfaceScale.metric(2)) {
                    ForEach(store.pullRequests) { build in
                        PullRequestRow(
                            build: build,
                            isInstalled: store.builds.contains { $0.id == installedBuildID && $0.pullRequest == build.pullRequest },
                            isSelected: store.selectedPullRequest == build.pullRequest
                        ) {
                            store.selectedPullRequest = build.pullRequest
                        }
                    }
                }
                .padding(InterfaceScale.metric(8))
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        Group {
            if let error = store.error {
                ContentUnavailableView {
                    Label("Couldn’t Load Builds", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    ModalGlassButton(symbol: "arrow.clockwise", label: "Try Again") { Task { await store.load() } }
                }
            } else if let build = store.selectedBuild {
                ScrollView {
                    VStack(alignment: .leading, spacing: InterfaceScale.metric(20)) {
                        detailHeader(build)
                        buildHistory
                        buildFacts(build)
                    }
                    .padding(InterfaceScale.metric(20))
                }
                .scrollBounceBehavior(.basedOnSize)
            } else if !store.isLoading {
                ContentUnavailableView("Select a Pull Request", systemImage: "arrow.triangle.branch")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quaternary.opacity(0.35), in: ConcentricRectangle(cornerRadius: InterfaceScale.metric(12)))
        .containerShape(.rect(cornerRadius: InterfaceScale.metric(12), style: .continuous))
        .padding([.trailing, .bottom], InterfaceScale.metric(12))
        .padding(.top, InterfaceScale.metric(8))
    }

    private func detailHeader(_ build: PullRequestBuild) -> some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(10)) {
            Link(destination: build.pullRequestURL) {
                Label("PR #\(build.pullRequest)", systemImage: "arrow.triangle.pull")
                    .font(.interface(.callout).weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, InterfaceScale.metric(10))
                    .frame(height: InterfaceScale.metric(26))
                    // Glass inside a scroll view escapes its clip as it scrolls.
                    .background(SakuraCordAccentColor.color, in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Open pull request on GitHub")
            Text(build.title)
                .font(.interface(.title2).weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private var buildHistory: some View {
        VStack(spacing: InterfaceScale.metric(2)) {
            ForEach(store.selectedBuilds) { build in
                BuildRow(
                    build: build,
                    badge: build.id == installedBuildID ? "Installed" : build.id == store.latestBuildID ? "Latest" : nil,
                    isSelected: store.selectedBuild?.id == build.id
                ) {
                    store.selectedBuildID = build.id
                }
            }
        }
        .padding(InterfaceScale.metric(4))
        .background(.background.opacity(0.6), in: ConcentricRectangle(cornerRadius: InterfaceScale.metric(12)))
        .containerShape(.rect(cornerRadius: InterfaceScale.metric(12), style: .continuous))
    }

    private func buildFacts(_ build: PullRequestBuild) -> some View {
        HStack(alignment: .top, spacing: InterfaceScale.metric(8)) {
            FactTile(title: "Version", systemImage: "shippingbox") {
                Text(build.version)
            }
            FactTile(title: "Built commit", systemImage: "number") {
                Text(String(build.builtSHA.prefix(12)))
                    .font(.interface(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .help(build.builtSHA)
            }
            FactTile(title: "CI run", systemImage: "gearshape.2") {
                Link("\(String(build.runID)) · #\(build.runAttempt)", destination: build.runURL)
                    .help("View CI run on GitHub")
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Spacer(minLength: InterfaceScale.metric(12))
            ModalGlassButton(symbol: "arrow.down.circle", label: "Install…", primary: canConfirmInstallation) { confirmingBuild = store.selectedBuild }
                .disabled(!canConfirmInstallation)
                .help(installHelp)
        }
        .padding(InterfaceScale.metric(12))
    }

    private var installHelp: LocalizedStringResource {
        if store.isPreview {
            "Preview the installation warning. Sample builds can’t be installed."
        } else if !updateController.canSwitchBuilds {
            "Updates are disabled or busy."
        } else {
            "Install the selected build"
        }
    }
}

// MARK: - Rows

private struct PullRequestRow: View {
    let build: PullRequestBuild
    let isInstalled: Bool
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: InterfaceScale.metric(10)) {
                Text("#\(String(build.pullRequest))")
                    .font(.interface(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .padding(.horizontal, InterfaceScale.metric(7))
                    .frame(height: InterfaceScale.metric(22))
                    .background(isSelected ? AnyShapeStyle(SakuraCordAccentColor.color) : AnyShapeStyle(.quaternary), in: Capsule())
                Text(build.title)
                    .font(.interface(.body).weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if isInstalled {
                    Image(systemName: "pin.fill").foregroundStyle(SakuraCordAccentColor.color)
                        .font(.interface(.caption))
                        .accessibilityLabel("Installed")
                }
            }
            .padding(InterfaceScale.metric(10))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(PopoverRowButtonStyle(isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct BuildRow: View {
    let build: PullRequestBuild
    let badge: LocalizedStringResource?
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: InterfaceScale.metric(10)) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.interface(.body))
                    .foregroundStyle(isSelected ? SakuraCordAccentColor.color : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: InterfaceScale.metric(2)) {
                    HStack(spacing: InterfaceScale.metric(6)) {
                        Text(build.commitSubject)
                            .font(.interface(.body).weight(.medium))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .help(build.commitSubject)
                        if let badge {
                            Text(badge)
                                .font(.interface(.caption2).weight(.semibold))
                                .fixedSize()
                                .padding(.horizontal, InterfaceScale.metric(6))
                                .frame(height: InterfaceScale.metric(18))
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    HStack(spacing: InterfaceScale.metric(6)) {
                        Text(build.shortCommit).font(.interface(.caption, design: .monospaced))
                        Text("·")
                        Text(build.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    }
                    .font(.interface(.caption)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, InterfaceScale.metric(10))
            .padding(.vertical, InterfaceScale.metric(8))
        }
        .buttonStyle(PopoverRowButtonStyle(isSelected: isSelected, cornerRadius: InterfaceScale.metric(8)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct FactTile<Value: View>: View {
    let title: LocalizedStringResource
    let systemImage: String
    @ViewBuilder let value: () -> Value

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(6)) {
            Label(title, systemImage: systemImage)
                .font(.interface(.caption).weight(.medium))
                .foregroundStyle(.secondary)
            value()
                .font(.interface(.callout))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(InterfaceScale.metric(12))
        .background(.background.opacity(0.6), in: ConcentricRectangle(cornerRadius: InterfaceScale.metric(12)))
        .accessibilityElement(children: .combine)
    }
}
