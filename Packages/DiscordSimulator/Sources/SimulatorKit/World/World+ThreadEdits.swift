import Foundation

/// Joining, leaving, muting, editing and deleting threads and forum posts.
extension World {
    func joinThread(_ threadID: Snowflake, by userID: Snowflake) async throws {
        let thread = try channel(threadID)
        guard thread.type.isThread else { throw WorldError.wrongChannelType }
        guard canView(userID, thread) else { throw WorldError.missingAccess }
        if thread.thread?.locked == true, !permissions(of: userID, in: thread).contains(.manageThreads) { throw WorldError.missingPermissions }
        guard !thread.threadMembers.contains(userID) else { return }
        channels[threadID]?.threadMembers.append(userID)
        let joined = channels[threadID]!
        await emitThreadMembers(joined, added: [userID], removed: [], extraRecipients: [])
        // The joiner now holds the thread, so it arrives as THREAD_CREATE with their membership.
        await emit("THREAD_CREATE", renderThread(joined, viewer: userID), to: .users([userID]))
    }

    func leaveThread(_ threadID: Snowflake, by userID: Snowflake) async throws {
        let thread = try channel(threadID)
        guard thread.type.isThread else { throw WorldError.wrongChannelType }
        guard thread.threadMembers.contains(userID) else { return }
        channels[threadID]?.threadMembers.removeAll { $0 == userID }
        channels[threadID]?.mutedThreadMembers.remove(userID)
        await emitThreadMembers(channels[threadID]!, added: [], removed: [userID], extraRecipients: [userID])
    }

    func setThreadMuted(_ threadID: Snowflake, by userID: Snowflake, muted: Bool) async throws -> JSON {
        let thread = try channel(threadID)
        guard thread.threadMembers.contains(userID) else { throw WorldError.unknown("Member", code: 10007) }
        if muted { channels[threadID]?.mutedThreadMembers.insert(userID) } else { channels[threadID]?.mutedThreadMembers.remove(userID) }
        await emitThreadMemberUpdate(channels[threadID]!, userID: userID)
        return renderThreadMember(channels[threadID]!, userID: userID, includeIDs: true)
    }

    /// `PATCH /channels/{id}` on a thread or forum post: name, archive, lock, tags.
    func editThread(_ threadID: Snowflake, by userID: Snowflake, patch: JSON) async throws -> Channel {
        var thread = try channel(threadID)
        guard thread.type.isThread, var metadata = thread.thread else {
            throw WorldError.wrongChannelType
        }
        guard canView(userID, thread) else { throw WorldError.missingAccess }
        let manages = permissions(of: userID, in: thread).contains(.manageThreads)
        // Captured: an owner renames and archives their own thread, the rename sending the thread's full settings
        // (`locked` unchanged among them). Documented, not captured: retagging; locking and editing others' need Manage Threads.
        let changesLock = patch["locked"]?.boolValue.map { $0 != metadata.locked } ?? false
        if !manages, thread.ownerID != userID || changesLock || metadata.locked { throw WorldError.missingPermissions }
        var renamed: String?
        if let name = patch["name"]?.stringValue {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1 ... 100).contains(trimmed.count) else { throw WorldError.invalidBody("name: Must be between 1 and 100 in length.") }
            if trimmed != thread.name { renamed = trimmed }
            thread.name = trimmed
        }
        if let archived = patch["archived"]?.boolValue, archived != metadata.archived {
            metadata.archived = archived
            metadata.archiveTimestamp = clock.now
        }
        if let locked = patch["locked"]?.boolValue { metadata.locked = locked }
        if let invitable = patch["invitable"]?.boolValue { metadata.invitable = invitable }
        if let duration = patch["auto_archive_duration"]?.intValue { metadata.autoArchiveDuration = Int(duration) }
        if let tags = patch["applied_tags"]?.arrayValue { thread.appliedTags = tags.compactMap { $0.stringValue.flatMap(Snowflake.init) } }
        thread.thread = metadata
        channels[threadID] = thread
        // Captured: a rename posts the "changed the title" system message (type 4) before THREAD_UPDATE.
        if let renamed {
            var notice = MessageDraft(content: renamed)
            notice.type = 4
            _ = try await sendSystemMessage(notice, as: userID, in: threadID)
            thread = channels[threadID] ?? thread
        }
        let parent = channels[thread.parentID ?? threadID] ?? thread
        await emit("THREAD_UPDATE", renderThread(thread, viewer: nil), to: audience(for: parent))
        // An open thread the editor belongs to also refreshes their membership.
        if !metadata.archived, thread.threadMembers.contains(userID) { await emitThreadMemberUpdate(thread, userID: userID) }
        return thread
    }

    func deleteThread(_ threadID: Snowflake, by userID: Snowflake) async throws -> Channel {
        let thread = try channel(threadID)
        try require(.manageThreads, userID, thread)
        let parent = channels[thread.parentID ?? threadID] ?? thread
        let audience = audience(for: parent)
        channels[threadID] = nil
        if let guildID = thread.guildID { guilds[guildID]?.channelIDs.removeAll { $0 == threadID } }
        var payload = JSONObject([("id", threadID.json), ("type", .int(thread.type.rawValue))])
        if let guildID = thread.guildID { payload["guild_id"] = guildID.json }
        if let parentID = thread.parentID { payload["parent_id"] = parentID.json }
        await emit("THREAD_DELETE", .object(payload), to: audience)
        return thread
    }

    /// THREAD_MEMBER_UPDATE: the user's own membership, sent only to them.
    func emitThreadMemberUpdate(_ thread: Channel, userID: Snowflake) async {
        let member = renderThreadMember(thread, userID: userID, includeIDs: true).merging(["guild_id": thread.guildID?.json ?? .null])
        await emit("THREAD_MEMBER_UPDATE", member, to: .users([userID]))
    }

    /// THREAD_MEMBERS_UPDATE goes to the thread's members, plus anyone who just left. Captures show
    /// the joiner and leaver receiving it; that other members do is assumed.
    private func emitThreadMembers(_ thread: Channel, added: [Snowflake], removed: [Snowflake], extraRecipients: Set<Snowflake>) async {
        var payload = JSONObject()
        if let guildID = thread.guildID { payload["guild_id"] = guildID.json }
        if !added.isEmpty {
            payload["added_members"] = .array(added.map { userID in
                var member = renderThreadMember(thread, userID: userID, includeIDs: true).merging(["join_timestamp": World.timestamp(clock.now)])
                if let guildID = thread.guildID, let guildMember = guilds[guildID]?.members[userID] {
                    member = member.merging(["member": renderMember(guildMember, guildID: guildID, includeUser: true)])
                }
                let status = presences[userID]?.status ?? .offline
                return member.merging(["presence": status == .offline || status == .invisible ? .null : renderPresence(userID, guildID: thread.guildID)])
            })
        }
        payload["id"] = thread.id.json
        payload["member_count"] = .int(thread.threadMembers.count)
        payload["member_ids_preview"] = .array(thread.threadMembers.prefix(8).map(\.json))
        if !removed.isEmpty { payload["removed_member_ids"] = .array(removed.map(\.json)) }
        await emit("THREAD_MEMBERS_UPDATE", .object(payload), to: .users(Set(thread.threadMembers).union(extraRecipients)))
    }
}
