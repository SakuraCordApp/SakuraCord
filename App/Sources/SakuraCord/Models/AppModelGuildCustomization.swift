import DiscordProtocol
import Foundation
import SakuraCordModels

extension AppModel {
    func synchronizeVisibleCustomization(guildID: GuildID?) {
        guard let guildID, onboarding.presentedGuildID == guildID, guildWorkspacePage == .channelsAndRoles else { return }
        startAccountChildTask(account: accountSession()) { model, _ in
            await model.synchronizeGuildCustomization(in: guildID)
        }
    }

    func customizationRoles(in guildID: GuildID) -> [GuildRole] {
        let member = onboardingMember(in: guildID)
        guard let entry = onboarding.entries[guildID], let configuration = entry.configuration else { return member?.roles ?? [] }
        let options = configuration.prompts.flatMap(\.options)
        let baseline = Set(configuration.responses)
        let removed = Set(options.filter { baseline.contains($0.id) && !entry.responses.contains($0.id) }.flatMap(\.roleIDs))
        let selected = Set(options.filter { entry.responses.contains($0.id) }.flatMap(\.roleIDs))
        let roleIDs = Set(member?.roles.map(\.id) ?? []).subtracting(removed).union(selected)
        return (guildRolesByGuildID[guildID] ?? []).filter { roleIDs.contains($0.id) && $0.id.rawValue != guildID.rawValue }
    }

    /// Reconcile a visible editor without disturbing focus or in-flight input.
    func synchronizeGuildCustomization(in guildID: GuildID) async {
        let account = accountSession()
        guard let entry = onboarding.entries[guildID], !entry.initial, !entry.isLoading, !entry.isSaving, !entry.isSynchronizing,
              isCurrentAccountSession(account) else { return }
        onboarding.entries[guildID]?.isSynchronizing = true
        defer {
            if isCurrentAccountSession(account), onboarding.entries[guildID]?.revision == entry.revision {
                onboarding.entries[guildID]?.isSynchronizing = false
            }
        }
        do {
            let confirmed = try await account.provider.guildOnboarding(in: guildID)
            guard isCurrentAccountSession(account), !Task.isCancelled,
                  let current = onboarding.entries[guildID], current.revision == entry.revision,
                  current.editRevision == entry.editRevision, !current.isSaving else { return }
            onboarding.entries[guildID]?.configuration = confirmed
            onboarding.entries[guildID]?.responses = confirmed.validResponses(Set(confirmed.responses), initial: false)
            onboarding.entries[guildID]?.needsRefresh = false
        } catch {
            // Preserve the last confirmed state during a transient read failure.
            // A failed user mutation supplies its own visible, actionable error.
        }
    }

    /// One worker per membership. Edits remain interactive while a write is in
    /// flight; its response updates the baseline without replacing newer input.
    func scheduleOnboardingAnswers(in guildID: GuildID) {
        let store = onboarding
        guard let entry = store.entries[guildID], !entry.initial, !entry.isSaving else { return }
        store.entries[guildID]?.isSaving = true
        let identity = entry.revision
        startAccountChildTask(account: accountSession()) { model, account in
            while model.isCurrentAccountSession(account), !Task.isCancelled,
                  store.entries[guildID]?.revision == identity {
                guard let pending = store.entries[guildID] else { return }
                do { try await store.customizationDebounce() } catch { return }
                guard model.isCurrentAccountSession(account), !Task.isCancelled,
                      let current = store.entries[guildID], current.revision == identity else { return }
                guard current.editRevision == pending.editRevision else { continue }
                if current.responses == Set(current.configuration?.responses ?? []) {
                    store.entries[guildID]?.isSaving = false
                    return
                }
                do {
                    let confirmed = try await account.provider.saveGuildOnboarding(
                        in: guildID, responses: current.responses, initial: false
                    )
                    guard model.isCurrentAccountSession(account), !Task.isCancelled,
                          store.entries[guildID]?.revision == identity else { return }
                    store.entries[guildID]?.configuration = confirmed
                    if store.entries[guildID]?.editRevision == current.editRevision {
                        store.entries[guildID]?.responses = Set(confirmed.responses)
                        store.entries[guildID]?.isSaving = false
                        return
                    }
                } catch {
                    // A lost response may still have reached Discord. Read back
                    // before rolling back, and never erase input made meanwhile.
                    let confirmed = try? await account.provider.guildOnboarding(in: guildID)
                    guard model.isCurrentAccountSession(account), !Task.isCancelled,
                          store.entries[guildID]?.revision == identity else { return }
                    if let confirmed { store.entries[guildID]?.configuration = confirmed }
                    store.entries[guildID]?.error = error.localizedDescription
                    if store.entries[guildID]?.editRevision == current.editRevision {
                        let baseline = store.entries[guildID]?.configuration
                        let rollback = baseline?.validResponses(Set(baseline?.responses ?? []), initial: false) ?? []
                        store.entries[guildID]?.responses = rollback
                        store.entries[guildID]?.isSaving = false
                        return
                    }
                }
            }
        }
    }
}
