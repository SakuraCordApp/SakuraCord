import SakuraCordModels
import SwiftUI

/// Gates the guild detail pane until Discord confirms completion.
struct GuildOnboardingView: View {
    let model: AppModel
    let guildID: GuildID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var movingForward = true
    @State private var navigationHeight: CGFloat = 40

    private let navigationInset: CGFloat = InterfaceScale.metric(16)
    private var cardRadius: CGFloat { navigationHeight / 2 + navigationInset }

    private var entry: GuildOnboardingStore.Entry { model.onboarding.entries[guildID] ?? .init() }
    private var guild: Guild? { model.serverRailGuildsByID[guildID] }
    private var prompts: [GuildOnboardingPrompt] { entry.configuration?.questions(initial: true) ?? [] }
    private var index: Int? { prompts.firstIndex { $0.id == entry.promptID } }
    private var working: Bool { entry.isSaving }

    var body: some View {
        ZStack {
            content
                .id(entry.configuration == nil ? "loading" : entry.promptID ?? "welcome")
                .transition(reduceMotion ? .opacity : .push(from: movingForward ? .trailing : .leading))
        }
        .frame(maxWidth: InterfaceScale.metric(820), maxHeight: InterfaceScale.metric(560))
        .padding(InterfaceScale.metric(24))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background { SakuraCordSignInBackdrop().ignoresSafeArea(edges: .top) }
        .tint(SakuraCordAccentColor.color)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Server Onboarding")
    }

    @ViewBuilder private var content: some View {
        if entry.configuration == nil {
            VStack(spacing: InterfaceScale.metric(20)) {
                if entry.isLoading { ProgressView().controlSize(.large) }
                if let error = entry.error {
                    ContentUnavailableView("Unable to Load Onboarding", systemImage: "wifi.exclamationmark", description: Text(error))
                    Button("Try Again") { model.refreshOnboarding(in: guildID) }.buttonStyle(.glassProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let index {
            questionCard(index: index)
        } else {
            welcome
        }
    }

    private var welcome: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: InterfaceScale.metric(24)) {
                    GuildWelcomeArtwork(guild: guild, size: 120)
                    Text("Welcome to \(guild?.name ?? "the server")")
                        .font(.interface(.title2)).multilineTextAlignment(.center)
                    Text("Let’s customize your experience")
                        .font(.interface(.largeTitle).weight(.semibold))
                        .multilineTextAlignment(.center)
                    OnboardingStatus(entry: entry)
                    Button(prompts.isEmpty ? "Finish Joining" : "Get Started", systemImage: "arrow.right") {
                        if let first = prompts.first { advance(to: first.id) } else { model.saveOnboarding(in: guildID) }
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.extraLarge)
                    .buttonBorderShape(.capsule)
                    .disabled(working || entry.needsRefresh || entry.isLoading)
                    if entry.needsRefresh { refreshButton }
                }
                .padding(InterfaceScale.metric(24))
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func questionCard(index: Int) -> some View {
        let prompt = prompts[index]
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: InterfaceScale.metric(24)) {
                    HStack {
                        Text("Question \(index + 1) of \(prompts.count)").foregroundStyle(.secondary)
                        if prompt.required { Text("Required").foregroundStyle(SakuraCordAccentColor.color) }
                    }
                    .font(.interface(.callout).weight(.medium))
                    OnboardingQuestion(model: model, guildID: guildID, prompt: prompt, large: true)
                    consequence(prompt)
                    OnboardingStatus(entry: entry)
                }
                .padding(InterfaceScale.metric(32)).frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .id(prompt.id)
            Divider().opacity(0.4)
            navigation(index: index)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { navigationHeight = $0 }
                .padding(navigationInset)
        }
        .background(.background.opacity(0.88), in: RoundedRectangle(cornerRadius: cardRadius))
        .overlay { RoundedRectangle(cornerRadius: cardRadius).stroke(.primary.opacity(0.06)) }
        .containerShape(RoundedRectangle(cornerRadius: cardRadius))
    }

    private func consequence(_ prompt: GuildOnboardingPrompt) -> some View {
        let options = prompt.options.filter { entry.responses.contains($0.id) }
        let channels = Set(options.flatMap(\.channelIDs))
        let roles = Set(options.flatMap(\.roleIDs))
        let names = model.messagePresentationChannels.filter { channels.contains($0.id) }.map { "#\($0.name)" }
        let roleNames = (model.guildRolesByGuildID[guildID] ?? model.guildRoles).filter { roles.contains($0.id) }.map { "@\($0.name)" }
        return VStack(alignment: .leading, spacing: InterfaceScale.metric(4)) {
            if model.featuresSettings.channelManagement, !names.isEmpty { Text("Channels: \(names.formatted())") }
            if !roleNames.isEmpty { Text("Roles: \(roleNames.formatted())") }
        }
        .font(.interface(.callout)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func navigation(index: Int) -> some View {
        HStack(spacing: InterfaceScale.metric(12)) {
            if index > 0 {
                Button("Back", systemImage: "arrow.left") { advance(to: prompts[index - 1].id) }
                    .buttonStyle(.glass).disabled(working)
            }
            Spacer(minLength: 0)
            if entry.needsRefresh { refreshButton }
            if entry.isSaving { ProgressView().controlSize(.small).accessibilityLabel("Saving answers") }
            Button(index + 1 < prompts.count ? "Next" : "Finish Joining", systemImage: "arrow.right") {
                if index + 1 < prompts.count { advance(to: prompts[index + 1].id) } else { model.saveOnboarding(in: guildID) }
            }
            .buttonStyle(.glassProminent)
            .disabled(working || entry.needsRefresh || (entry.isLoading && index + 1 == prompts.count) || !canAdvance(prompts[index]))
        }
        .controlSize(.extraLarge)
        .buttonBorderShape(.capsule)
    }

    private var refreshButton: some View {
        Button("Refresh", systemImage: "arrow.clockwise") { model.refreshOnboarding(in: guildID) }.buttonStyle(.glass).disabled(working)
    }

    private func canAdvance(_ prompt: GuildOnboardingPrompt) -> Bool {
        let count = prompt.options.filter { entry.responses.contains($0.id) }.count
        return (!prompt.required || count > 0) && (!prompt.singleSelect || count <= 1) && [0, 1].contains(prompt.type)
    }

    private func advance(to promptID: String) {
        movingForward = (prompts.firstIndex { $0.id == promptID } ?? 0) >= (index ?? -1)
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.3)) {
            model.setOnboardingPrompt(promptID, guildID: guildID)
        }
    }
}

struct GuildWelcomeArtwork: View {
    let guild: Guild?
    var size: CGFloat = 88
    var body: some View {
        AsyncImage(url: guild?.iconURL) { image in image.resizable().scaledToFill() } placeholder: {
            Image(systemName: "sparkles").font(.system(size: size * 0.4)).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SakuraCordAccentColor.color.gradient)
        }
        .frame(width: size, height: size)
        .clipShape(ConcentricRectangle(cornerRadius: size * 0.25))
        .shadow(color: SakuraCordAccentColor.color.opacity(0.22), radius: InterfaceScale.metric(30), y: 12)
        .accessibilityHidden(true)
    }
}

struct OnboardingStatus: View {
    let entry: GuildOnboardingStore.Entry
    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(8)) {
            if let notice = entry.notice { Text(notice).foregroundStyle(.secondary) }
            if let error = entry.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
        }
        .font(.interface(.callout)).fixedSize(horizontal: false, vertical: true)
    }
}
