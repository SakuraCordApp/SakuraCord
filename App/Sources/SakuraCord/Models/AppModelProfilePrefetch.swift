import SakuraCordModels

extension AppModel {
    func beginCurrentUserProfilePrefetch(
        in guildID: GuildID?,
        account session: AppModelAccountSession?
    ) {
        guard let session, let user = snapshot?.currentUser else { return }
        let cacheKey = ProfileCacheKey(userID: user.id, guildID: guildID)
        guard profileCache[cacheKey] == nil,
              currentUserProfilePrefetch?.key != cacheKey
        else { return }

        currentUserProfilePrefetch?.task.cancel()
        let task = startAccountChildTask(account: session) { model, session in
            defer {
                if model.currentUserProfilePrefetch?.key == cacheKey {
                    model.currentUserProfilePrefetch = nil
                }
            }
            do {
                let profile = try await session.provider.profile(
                    for: user.id,
                    in: guildID
                )
                guard !Task.isCancelled,
                      model.isCurrentAccountSession(session)
                else { return }
                model.profileCache[cacheKey] = profile
            } catch {
                // Prefetching is speculative. The normal profile presentation
                // path remains responsible for surfacing load failures.
            }
        }
        currentUserProfilePrefetch = CurrentUserProfilePrefetch(
            key: cacheKey,
            task: task
        )
    }
}
