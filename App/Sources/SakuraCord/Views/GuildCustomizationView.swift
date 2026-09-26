import SakuraCordModels
import SwiftUI

struct GuildCustomizationView: View {
    let model: AppModel
    let guildID: GuildID
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsChannels = false
    @State private var newPromptIDs: Set<String>?
    private var entry: GuildOnboardingStore.Entry { model.onboarding.entries[guildID] ?? .init() }

    var body: some View {
        VStack(spacing: 0) {
            if model.featuresSettings.channelManagement {
                HStack {
                    Picker("Customize", selection: $showsChannels) {
                        Text("Customize").tag(false)
                        Text("Browse Channels").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)
                    Spacer()
                }
                .padding(24)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let error = entry.error {
                        HStack {
                            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                            if entry.needsRefresh {
                                Button("Try Again") { model.refreshOnboarding(in: guildID) }.buttonStyle(.glass)
                            }
                        }
                        .font(.callout)
                    }
                    if let configuration = entry.configuration, configuration.enabled {
                        if showsChannels, model.featuresSettings.channelManagement {
                            GuildOnboardingChannelsView(model: model, guildID: guildID, configuration: configuration)
                        } else {
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .top, spacing: 32) {
                                    questions(configuration).frame(minWidth: 400, maxWidth: .infinity)
                                    profile.frame(width: 230)
                                }
                                VStack(alignment: .leading, spacing: 32) { questions(configuration); profile }
                            }
                        }
                    } else if entry.isLoading {
                        ProgressView("Loading…").frame(maxWidth: .infinity)
                    } else {
                        ContentUnavailableView("Customization Unavailable", systemImage: "slider.horizontal.3", description: Text("This server hasn’t enabled onboarding customization."))
                    }
                }
                .padding(24).frame(maxWidth: 1200).frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
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
        return VStack(alignment: .leading, spacing: 24) {
            if !new.isEmpty {
                Text("New Options").font(.headline)
                ForEach(new) { questionCard($0) }
                if !previous.isEmpty { Divider().padding(.vertical, 8) }
            }
            if !previous.isEmpty {
                Text("Customization Questions").font(.headline)
                ForEach(previous) { questionCard($0) }
            }
            if prompts.isEmpty {
                ContentUnavailableView("No Questions", systemImage: "list.bullet", description: Text("This server hasn’t added customization questions."))
            }
        }
    }

    private func questionCard(_ prompt: GuildOnboardingPrompt) -> some View {
        OnboardingQuestion(model: model, guildID: guildID, prompt: prompt)
            .padding(20)
            .background(.primary.opacity(0.025), in: ConcentricRectangle(cornerRadius: 20))
            .overlay { ConcentricRectangle(cornerRadius: 20).stroke(.primary.opacity(0.08)) }
            .containerShape(RoundedRectangle(cornerRadius: 20))
    }

    private var profile: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("My Profile").font(.headline)
            if let user = model.currentUser {
                AsyncImage(url: user.avatarURL) { image in image.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.2) }
                    .frame(width: 80, height: 80).clipShape(Circle())
                Text(user.displayName).font(.title2.weight(.semibold))
            }
            Divider()
            Text("Roles").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ProfileRolesSection(roles: model.customizationRoles(in: guildID), keepsExpanded: true)
                .padding(.horizontal, -16)
        }
    }
}
