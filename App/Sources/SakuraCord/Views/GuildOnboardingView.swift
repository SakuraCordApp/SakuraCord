import SakuraCordModels
import SwiftUI

/// Replaces the entire guild workspace until Discord confirms completion.
struct GuildOnboardingView: View {
    let model: AppModel
    let guildID: GuildID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = true

    private var entry: GuildOnboardingStore.Entry { model.onboarding.entries[guildID] ?? .init() }
    private var guild: Guild? { model.serverRailGuildsByID[guildID] }
    private var prompts: [GuildOnboardingPrompt] { entry.configuration?.questions(initial: true) ?? [] }
    private var index: Int? { prompts.firstIndex { $0.id == entry.promptID } }
    private var working: Bool { entry.isSaving }

    var body: some View {
        ZStack {
            SakuraCordSignInBackdrop()
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                content
                    .modifier(SakuraCordSignInReveal(isVisible: revealed, reduceMotion: reduceMotion))
                    .frame(maxWidth: 820, maxHeight: 650)
                    .padding(.horizontal, 32)
                    .padding(.top, 32)
                Spacer(minLength: 0)
                Link("Discord Privacy Policy", destination: URL(string: "https://discord.com/privacy")!)
                    .font(.caption).foregroundStyle(.secondary).padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(SakuraCordAccentColor.color)
        .onChange(of: entry.promptID) { old, new in
            guard old != new else { return }
            revealed = false
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(40))
                guard entry.promptID == new else { return }
                withAnimation(SakuraCordSignInReveal.animation(reduceMotion: reduceMotion)) { revealed = true }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Server Onboarding")
    }

    @ViewBuilder private var content: some View {
        if entry.configuration == nil {
            VStack(spacing: 20) {
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
        ScrollView {
            VStack(spacing: 24) {
                GuildWelcomeArtwork(guild: guild, size: 180)
                Text("Welcome to \(guild?.name ?? "the server")")
                    .font(.title2).multilineTextAlignment(.center)
                Text("Let’s customize your experience")
                    .font(.system(size: 38, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                OnboardingStatus(entry: entry)
                if prompts.isEmpty {
                    Button("Finish Joining", systemImage: "arrow.right") { model.saveOnboarding(in: guildID) }
                        .buttonStyle(.glassProminent).controlSize(.extraLarge)
                        .disabled(working || entry.needsRefresh)
                }
                if entry.needsRefresh { refreshButton }
            }
            .padding(32).frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .task(id: entry.isLoading) {
            guard !working, !entry.needsRefresh, let first = prompts.first else { return }
            do { try await Task.sleep(for: .seconds(reduceMotion ? 0 : 2)) } catch { return }
            guard entry.promptID == nil else { return }
            advance(to: first.id)
        }
    }

    private func questionCard(index: Int) -> some View {
        let prompt = prompts[index]
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        Text("Question \(index + 1) of \(prompts.count)").foregroundStyle(.secondary)
                        if prompt.required { Text("Required").foregroundStyle(SakuraCordAccentColor.color) }
                    }
                    .font(.callout.weight(.medium))
                    OnboardingQuestion(model: model, guildID: guildID, prompt: prompt, large: true)
                    OnboardingStatus(entry: entry)
                }
                .padding(32).frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .id(prompt.id)
            Divider().opacity(0.4)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) { consequence(prompt); Spacer(minLength: 0); navigation(index: index) }
                VStack(alignment: .leading, spacing: 16) { consequence(prompt); HStack { Spacer(); navigation(index: index) } }
            }
            .padding(24)
        }
        .background(.background.opacity(0.88), in: ConcentricRectangle(cornerRadius: 32))
        .overlay { ConcentricRectangle(cornerRadius: 32).stroke(.primary.opacity(0.06)) }
        .containerShape(RoundedRectangle(cornerRadius: 32))
    }

    private func consequence(_ prompt: GuildOnboardingPrompt) -> some View {
        let options = prompt.options.filter { entry.responses.contains($0.id) }
        let channels = Set(options.flatMap(\.channelIDs))
        let roles = Set(options.flatMap(\.roleIDs))
        let names = (model.snapshot?.channels ?? []).filter { channels.contains($0.id) }.map { "#\($0.name)" }
        let roleNames = (model.guildRolesByGuildID[guildID] ?? model.guildRoles).filter { roles.contains($0.id) }.map { "@\($0.name)" }
        return VStack(alignment: .leading, spacing: 4) {
            if !names.isEmpty { Text("Channels: " + names.joined(separator: ", ")) }
            if !roleNames.isEmpty { Text("Roles: " + roleNames.joined(separator: ", ")) }
        }
        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func navigation(index: Int) -> some View {
        HStack(spacing: 12) {
            if entry.needsRefresh { refreshButton }
            if index > 0 {
                Button("Back", systemImage: "arrow.left") { advance(to: prompts[index - 1].id) }
                    .buttonStyle(.glass).disabled(working)
            }
            if entry.isSaving { ProgressView().controlSize(.small) }
            Button(index + 1 < prompts.count ? "Next" : "Finish Joining", systemImage: "arrow.right") {
                if index + 1 < prompts.count { advance(to: prompts[index + 1].id) } else { model.saveOnboarding(in: guildID) }
            }
            .buttonStyle(.glassProminent)
            .disabled(working || entry.needsRefresh || (entry.isLoading && index + 1 == prompts.count) || !canAdvance(prompts[index]))
        }
        .controlSize(.large)
        .buttonBorderShape(.roundedRectangle(radius: 8))
    }

    private var refreshButton: some View {
        Button("Refresh", systemImage: "arrow.clockwise") { model.refreshOnboarding(in: guildID) }.buttonStyle(.glass).disabled(working)
    }

    private func canAdvance(_ prompt: GuildOnboardingPrompt) -> Bool {
        let count = prompt.options.filter { entry.responses.contains($0.id) }.count
        return (!prompt.required || count > 0) && (!prompt.singleSelect || count <= 1) && [0, 1].contains(prompt.type)
    }

    private func advance(to promptID: String) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) {
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
        .shadow(color: SakuraCordAccentColor.color.opacity(0.22), radius: 30, y: 12)
        .accessibilityHidden(true)
    }
}

struct OnboardingStatus: View {
    let entry: GuildOnboardingStore.Entry
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notice = entry.notice { Text(notice).foregroundStyle(.secondary) }
            if let error = entry.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
        }
        .font(.callout).fixedSize(horizontal: false, vertical: true)
    }
}
