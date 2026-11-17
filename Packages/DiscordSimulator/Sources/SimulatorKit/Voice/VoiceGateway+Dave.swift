import Foundation

/// One voice room's DAVE group as the voice server sees it.
final class DaveRoom {
    struct Round {
        var adds: [(userID: Snowflake, keyPackage: Data)]
        var removes: [Snowflake]
        /// Members asked to commit (op 27); the first commit wins.
        var committers: [Snowflake]
        var creating: Bool
    }

    let externalSender: DaveExternalSender
    /// The MLS group ID: the voice channel, or a Go Live stream's RTC channel (clients use the channel they identify with).
    let groupID: Snowflake
    /// Nil until the group exists.
    var epoch: UInt32?
    var leaves: [UInt32: Snowflake] = [:]
    var keyPackages: [(userID: Snowflake, keyPackage: Data)] = []
    var removals: [Snowflake] = []
    var round: Round?
    var transition: (id: UInt16, waiting: Set<Snowflake>)?
    var lastTransition: UInt16 = 0
    var simulated: [Snowflake: DaveMember] = [:]

    init(externalSender: DaveExternalSender, groupID: Snowflake) {
        self.externalSender = externalSender
        self.groupID = groupID
    }

    var members: Set<Snowflake> { Set(leaves.values) }
}

/// DAVE end-to-end encryption on the voice gateway (protocol version 1), from
/// Discord's DAVE protocol (github.com/discord/dave-protocol): the server is
/// the MLS external sender. It hands out its package (op 25), turns key
/// packages (op 26) and departures into add/remove proposals (op 27), takes the
/// first commit (op 28) and announces it (op 29) with a welcome for new members
/// (op 30), then executes the transition (op 22) once everyone is ready (op 23).
/// A group left with one member starts over with op 24 (prepare epoch 1).
/// A member that can't apply one (op 31) is removed and re-added. Simulated
/// people are real members through libdave and encrypt their media with it.
extension VoiceGateway {
    /// Op 25 for a client that selected DAVE.
    func daveJoined(_ client: Client) async {
        let groupID = await world.stream(rtcServerID: client.grant.room)?.rtcChannelID ?? client.grant.channelID
        guard let room = daveRoom(client.grant.room, groupID: groupID) else { return }
        sendBinary(25, room.externalSender.package, to: client)
        await syncDave(in: client.grant.room)
    }

    /// Ops 26 (key package) and 28 (commit and welcome), binary: opcode then payload.
    func receiveDave(_ message: Data, from client: Client) async {
        guard let op = message.first, let room = daveRooms[client.grant.room] else { return }
        let payload = Data(message.dropFirst())
        switch op {
        case 26:
            room.keyPackages.removeAll { $0.userID == client.grant.userID }
            room.keyPackages.append((client.grant.userID, payload))
        case 28:
            guard let round = room.round, round.committers.contains(client.grant.userID) else { return }
            await finish(round, commitWelcome: payload, in: client.grant.room, room: room)
        default:
            log.error("voice", "unknown binary voice opcode \(op)")
        }
        await advanceDave(in: client.grant.room)
    }

    /// Op 23: a member is ready for the transition; op 31: it couldn't apply it and starts over.
    func daveTransitionReply(_ op: Int64, _ data: JSON, from client: Client) async {
        guard let room = daveRooms[client.grant.room] else { return }
        if op == 31 {
            room.removals.append(client.grant.userID)
        } else if let transition = room.transition, data["transition_id"]?.intValue == Int64(transition.id) {
            room.transition?.waiting.remove(client.grant.userID)
        }
        await executeIfReady(in: client.grant.room, room: room)
    }

    /// Keeps simulated members in step with who is in the room and proposes removing anyone who left.
    func syncDave(in roomID: Snowflake) async {
        guard let room = daveRooms[roomID] else { return }
        let connected = Set(daveClients(in: roomID).map(\.grant.userID))
        guard !connected.isEmpty else {
            daveRooms[roomID] = nil
            await media.setDave(nil, in: roomID)
            return
        }
        let present = await world.mediaParticipants(in: roomID)
        let simulated = present.filter(\.simulated).map(\.userID)
        let everyone = Set(simulated).union(connected)
        for userID in simulated where room.simulated[userID] == nil { enlist(userID, in: room, recognizing: everyone) }
        for member in room.simulated.values { everyone.forEach(member.recognize) }
        room.keyPackages.removeAll { !everyone.contains($0.userID) }
        room.simulated = room.simulated.filter { everyone.contains($0.key) }
        for userID in room.members where !everyone.contains(userID) && !room.removals.contains(userID) { room.removals.append(userID) }
        await media.setDave(room.simulated, in: roomID)
        await advanceDave(in: roomID)
    }

    /// Starts the next proposal round when nothing is in flight.
    private func advanceDave(in roomID: Snowflake) async {
        guard let room = daveRooms[roomID], room.round == nil, room.transition == nil else { return }
        if room.epoch != nil, !room.removals.isEmpty, room.members.subtracting(room.removals).count < 2 {
            return await resetGroup(in: roomID, room: room)
        }
        let removes = room.removals.filter(room.members.contains)
        room.removals = []
        let creating = room.epoch == nil
        // A group needs two members; the creator (a simulated person when there is one) commits the rest.
        let creator = creating ? (room.keyPackages.first { room.simulated[$0.userID] != nil } ?? room.keyPackages.first) : nil
        let adds = room.keyPackages.filter { $0.userID != creator?.userID }
        guard !adds.isEmpty || !removes.isEmpty else { return }
        let epoch = room.epoch ?? 0
        let proposals = Dave.combine(proposals: removes.compactMap { userID in
            room.leaves.first { $0.value == userID }.map { room.externalSender.proposeRemove(epoch: epoch, leaf: $0.key) }
        } + adds.map { room.externalSender.proposeAdd(epoch: epoch, keyPackage: $0.keyPackage) })
        let committers = creator.map { [$0.userID] } ?? room.members.subtracting(removes).sorted()
        // The round uses every waiting key package: the creator's founds the group, the rest are added.
        room.keyPackages = []
        let round = DaveRoom.Round(adds: adds, removes: removes, committers: committers, creating: creating)
        room.round = round
        var winner: Data?
        for userID in committers {
            if let member = room.simulated[userID] {
                let commit = member.commit(proposals: proposals)
                if winner == nil, !commit.isEmpty { winner = commit }
            } else {
                for client in daveClients(in: roomID) where client.grant.userID == userID { sendBinary(27, proposals, to: client) }
            }
        }
        if let winner { await finish(round, commitWelcome: winner, in: roomID, room: room) }
    }

    /// Applies the winning commit: the roster and epoch move on, members get op 29 and joiners op 30.
    private func finish(_ round: DaveRoom.Round, commitWelcome: Data, in roomID: Snowflake, room: DaveRoom) async {
        let (commit, welcome) = room.externalSender.split(commitWelcome: commitWelcome)
        room.round = nil
        if round.creating, let creator = round.committers.first { room.leaves = [0: creator] }
        room.leaves = room.leaves.filter { !round.removes.contains($0.value) }
        for add in round.adds {
            let leaf = (0...).first { room.leaves[UInt32($0)] == nil }.map(UInt32.init) ?? 0
            room.leaves[leaf] = add.userID
        }
        room.epoch = (room.epoch ?? 0) + 1
        room.lastTransition = room.lastTransition == .max ? 1 : room.lastTransition + 1
        let transition = room.lastTransition
        var waiting: Set<Snowflake> = []
        let header = withUnsafeBytes(of: transition.bigEndian) { Data($0) }
        for client in daveClients(in: roomID) where room.members.contains(client.grant.userID) {
            let joining = round.adds.contains { $0.userID == client.grant.userID }
            sendBinary(joining ? 30 : 29, header + (joining ? welcome : commit), to: client)
            waiting.insert(client.grant.userID)
        }
        for (userID, member) in room.simulated {
            if round.adds.contains(where: { $0.userID == userID }) { member.join(welcome: welcome) } else if room.members.contains(userID) { member.apply(commit: commit) }
        }
        room.transition = (transition, waiting)
        await executeIfReady(in: roomID, room: room)
        // A member that never answers doesn't hold the group back.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            await self?.forceTransition(transition, in: roomID)
        }
    }

    /// A group down to one member starts over: op 24 with epoch 1 (and no transition ID, as Discord
    /// sends it and the official client parses it), after which members send new key packages.
    private func resetGroup(in roomID: Snowflake, room: DaveRoom) async {
        let remaining = room.members.subtracting(room.removals)
        room.epoch = nil
        room.leaves = [:]
        room.removals = []
        room.keyPackages = []
        for client in daveClients(in: roomID) where remaining.contains(client.grant.userID) {
            send(24, .object(JSONObject([("protocol_version", 1), ("epoch", 1)])), to: client)
        }
        for userID in remaining where room.simulated[userID] != nil { enlist(userID, in: room, recognizing: remaining) }
        await media.setDave(room.simulated, in: roomID)
    }

    /// A simulated person's fresh member, with its key package waiting for the next round.
    private func enlist(_ userID: Snowflake, in room: DaveRoom, recognizing others: Set<Snowflake>) {
        guard let member = DaveMember(userID: userID, groupID: room.groupID, externalSender: room.externalSender.package, recognized: Array(others))
        else { return }
        room.simulated[userID] = member
        room.keyPackages.append((userID, member.keyPackage()))
    }

    private func forceTransition(_ transition: UInt16, in roomID: Snowflake) async {
        guard let room = daveRooms[roomID], room.transition?.id == transition else { return }
        room.transition?.waiting = []
        await executeIfReady(in: roomID, room: room)
    }

    /// Op 22 once every member is ready; simulated members switch to the new keys.
    private func executeIfReady(in roomID: Snowflake, room: DaveRoom) async {
        guard let transition = room.transition, transition.waiting.isEmpty else {
            if room.transition == nil { await advanceDave(in: roomID) }
            return
        }
        room.transition = nil
        for client in daveClients(in: roomID) where room.members.contains(client.grant.userID) {
            send(22, .object(JSONObject([("transition_id", .int(Int64(transition.id)))])), to: client)
        }
        for (userID, member) in room.simulated where room.members.contains(userID) { member.useCurrentKey() }
        await advanceDave(in: roomID)
    }

    private func daveRoom(_ roomID: Snowflake, groupID: Snowflake) -> DaveRoom? {
        if let room = daveRooms[roomID] { return room }
        guard let sender = DaveExternalSender(groupID: groupID) else { return nil }
        let room = DaveRoom(externalSender: sender, groupID: groupID)
        daveRooms[roomID] = room
        return room
    }
}
