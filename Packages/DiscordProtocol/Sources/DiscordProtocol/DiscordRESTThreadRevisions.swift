import SakuraCordModels

/// The revisions that tell a REST thread result apart from newer state.
struct ThreadRevisionState {
    /// Advanced by each authoritative thread record or deletion; a REST
    /// result is applied only when no newer record arrived meanwhile.
    var records: [ChannelID: UInt64] = [:]
    /// Advanced by authoritative membership changes and each local join or
    /// leave; a REST result carries membership only when none arrived meanwhile.
    var memberships: [ChannelID: UInt64] = [:]
    /// Advanced only by changes that supersede a pending mutation's result:
    /// Gateway records and deletions, and accepted local mutations. Reads
    /// advance the revisions above but never these, so an observation cannot
    /// cancel a mutation's confirmation.
    var recordEpochs: [ChannelID: UInt64] = [:]
    /// Gateway membership events and the start of each local join or leave.
    var membershipEpochs: [ChannelID: UInt64] = [:]
}

struct ThreadRevisionBaseline {
    let records: [ChannelID: UInt64]
    let memberships: [ChannelID: UInt64]
}

extension DiscordRESTProvider {
    /// The thread revisions when a REST read starts. Capturing the whole maps
    /// also covers threads unknown at that moment: a later record or deletion
    /// gives them a revision the baseline lacks.
    func threadRevisionBaseline() -> ThreadRevisionBaseline {
        ThreadRevisionBaseline(records: threadRevisions.records, memberships: threadRevisions.memberships)
    }

    /// Every accepted membership change advances the revision that
    /// invalidates reads in flight. An `authoritative` change, a Gateway
    /// event or a local join/leave, also supersedes a pending one.
    @discardableResult
    func advanceThreadMembershipRevision(_ threadID: ChannelID, authoritative: Bool = true) -> UInt64 {
        let revision = (threadRevisions.memberships[threadID] ?? 0) &+ 1
        threadRevisions.memberships[threadID] = revision
        if authoritative { threadRevisions.membershipEpochs[threadID] = (threadRevisions.membershipEpochs[threadID] ?? 0) &+ 1 }
        return revision
    }

    func advanceThreadRecordRevision(_ threadID: ChannelID, includesMembership: Bool, authoritative: Bool = true) {
        threadRevisions.records[threadID] = (threadRevisions.records[threadID] ?? 0) &+ 1
        if authoritative { threadRevisions.recordEpochs[threadID] = (threadRevisions.recordEpochs[threadID] ?? 0) &+ 1 }
        if includesMembership { advanceThreadMembershipRevision(threadID, authoritative: authoritative) }
    }
}
