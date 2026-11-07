import SakuraCordModels
import SwiftUI

struct GuildCustomizationView: View {
    let model: AppModel
    let guildID: GuildID
    @Environment(\.scenePhase) private var scenePhase
    @State private var newPromptIDs: Set<String>?
    private var entry: GuildOnboardingStore.Entry { model.onboarding.entries[guildID] ?? .init() }

    var body: some View {
        primaryContent
            .onDisappear { model.closeCustomizationPreview() }
    }

    private var primaryContent: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: InterfaceScale.metric(24)) {
                    if let error = entry.error {
                        HStack {
                            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                            if entry.needsRefresh {
                                Button("Try Again") { model.refreshOnboarding(in: guildID) }.buttonStyle(.glass)
                            }
                        }
                        .font(.interface(.callout))
                    }
                    if model.isBrowsingGuildChannels {
                        GuildOnboardingChannelsView(model: model, guildID: guildID, search: model.onboarding.channelSearch)
                    } else if let configuration = entry.configuration {
                        Group {
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .top, spacing: InterfaceScale.metric(32)) {
                                    questions(configuration).frame(minWidth: InterfaceScale.metric(380), maxWidth: .infinity)
                                    profile.frame(width: InterfaceScale.metric(230))
                                }
                                VStack(alignment: .leading, spacing: InterfaceScale.metric(32)) { questions(configuration); profile }
                            }
                        }
                    } else if entry.isLoading {
                        ProgressView("Loading…").frame(maxWidth: .infinity)
                    } else if entry.error == nil {
                        ContentUnavailableView("Customization Unavailable", systemImage: "slider.horizontal.3", description: Text("This server hasn’t enabled onboarding customization."))
                    }
                }
                .padding(InterfaceScale.metric(24)).frame(maxWidth: InterfaceScale.metric(1200)).frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.always, axes: .vertical)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(SakuraCordAccentColor.color)
        .onChange(of: entry.configuration != nil, initial: true) { _, loaded in
            if loaded, newPromptIDs == nil, let configuration = entry.configuration {
                newPromptIDs = Set(configuration.prompts.filter { configuration.hasNewOptions($0) }.map(\.id))
            }
        }
        .task(id: "\(guildID)-\(model.currentUser?.id.description ?? "")-\(scenePhase)") {
            guard scenePhase == .active else { return }
            await model.loadCustomizationProfile(in: guildID)
            while !Task.isCancelled {
                if model.mainWindowIsActive { await model.synchronizeGuildCustomization(in: guildID) }
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }

    private func questions(_ configuration: GuildOnboarding) -> some View {
        let prompts = configuration.customizationQuestions
        // Keep question identity and placement stable while answers are saved,
        // including an open menu. Seen metadata takes effect on the next visit.
        let newIDs = newPromptIDs ?? Set(prompts.filter { configuration.hasNewOptions($0) }.map(\.id))
        let new = prompts.filter { newIDs.contains($0.id) }
        let previous = prompts.filter { !newIDs.contains($0.id) }
        return VStack(alignment: .leading, spacing: InterfaceScale.metric(24)) {
            if !new.isEmpty {
                Text("New Options").font(.interface(.headline))
                ForEach(new) { questionCard($0) }
                if !previous.isEmpty { Divider().padding(.vertical, InterfaceScale.metric(8)) }
            }
            if !previous.isEmpty {
                Text("Customization Questions").font(.interface(.headline))
                ForEach(previous) { questionCard($0) }
            }
            if prompts.isEmpty {
                ContentUnavailableView("No Questions", systemImage: "list.bullet", description: Text("This server hasn’t added customization questions."))
            }
        }
    }

    private func questionCard(_ prompt: GuildOnboardingPrompt) -> some View {
        // A concentric card inherits the window radius and turns oval when tall.
        let shape = RoundedRectangle(cornerRadius: InterfaceScale.metric(20), style: .continuous)
        return OnboardingQuestion(model: model, guildID: guildID, prompt: prompt)
            .padding(InterfaceScale.metric(20))
            .background(.primary.opacity(0.025), in: shape)
            .overlay { shape.stroke(.primary.opacity(0.08)) }
            .containerShape(shape)
    }

    private var profile: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(20)) {
            Text("My Profile").font(.interface(.headline))
            if let user = model.currentUser {
                let member = model.onboardingMember(in: guildID)
                AsyncImage(url: member?.guildAvatarURL ?? user.avatarURL) { image in image.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.2) }
                    .frame(width: InterfaceScale.metric(80), height: InterfaceScale.metric(80)).clipShape(Circle())
                Text(member?.guildNickname ?? user.displayName).font(.interface(.title2).weight(.semibold))
            }
            if let bio = model.onboarding.profiles[guildID]?.bio, !bio.isEmpty {
                ProfileRichTextView(source: bio).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            Text("Roles").font(.interface(.caption).weight(.semibold)).foregroundStyle(.secondary)
            ProfileRolesSection(roles: model.customizationRoles(in: guildID), keepsExpanded: true)
                .padding(.horizontal, -InterfaceScale.metric(16))
        }
    }
}
