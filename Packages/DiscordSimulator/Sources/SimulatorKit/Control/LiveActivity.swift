import Foundation

/// A generated server's measured traffic, which the `live-activity` script replays.
struct LiveActivityPlan: Sendable {
    var guildID: Snowflake
    var kind: CommunityKind
    /// Channels that hold messages, busiest first, and each one's share of the messages.
    var channels: [Snowflake]
    var shares: [Double]
    var voiceChannels: [Snowflake]
    var members: [Snowflake]
    var rates: ActivityProfile
    /// Voice joins and leaves per hour.
    var voiceMoves: Double
}

extension World {
    func addLiveActivity(_ plan: LiveActivityPlan) { liveActivity.append(plan) }
}

/// The demo modes' constant background life: messages, replies, typing,
/// reactions, edits, deletes, presence changes and voice joins at each
/// server's measured rates. A seeded Poisson process picks what happens and
/// when, so the sequence is the same every run. Params: `scale` (default 1)
/// multiplies every rate; `seconds` stops it after that long.
enum LiveActivity {
    static let name = "live-activity"

    private enum Kind: CaseIterable { case message, typing, reaction, presence, edit, delete, voice }

    private struct Stream {
        var plan: Int
        var kind: Kind
        var perSecond: Double
    }

    static let script: ScriptRunner.Script = { world, params in
        let plans = await world.liveActivity
        let scale = params["scale"]?.doubleValue ?? 1
        var streams: [Stream] = []
        for (index, plan) in plans.enumerated() {
            let rates: [Kind: Double] = [.message: plan.rates.messages, .typing: plan.rates.typing, .reaction: plan.rates.reactions,
                                         .presence: plan.rates.presence, .edit: plan.rates.edits, .delete: plan.rates.deletes,
                                         .voice: plan.voiceMoves]
            for kind in Kind.allCases where rates[kind, default: 0] > 0 {
                streams.append(Stream(plan: index, kind: kind, perSecond: rates[kind, default: 0] * scale / 3_600))
            }
        }
        let total = streams.reduce(0) { $0 + $1.perSecond }
        guard total > 0 else { return }
        var random = SeededRandom(seed: world.seed).fork(name)
        let deadline = params["seconds"]?.doubleValue.map { ContinuousClock.now + .seconds($0) }
        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(min(30, -log(1 - random.unit()) / total)))
            if let deadline, ContinuousClock.now >= deadline { return }
            var pick = random.unit() * total
            let stream = streams.first { pick -= $0.perSecond; return pick < 0 } ?? streams[streams.count - 1]
            // A step that no longer applies (a deleted message, a full channel) is skipped, like a person changing their mind.
            try? await perform(stream.kind, plans[stream.plan], world, &random)
        }
    }

    private static func perform(_ kind: Kind, _ plan: LiveActivityPlan, _ world: World, _ random: inout SeededRandom) async throws {
        guard !plan.members.isEmpty, !plan.channels.isEmpty else { return }
        let person = random.pick(plan.members)
        let channel = pickChannel(plan, &random)
        switch kind {
        case .message:
            var draft = MessageDraft(content: DemoText.communityMessage(plan.kind, &random))
            if random.chance(0.15), let recent = try await world.channel(channel).messages.last {
                draft.type = 19
                draft.reference = MessageReference(type: 0, messageID: recent.id, channelID: channel, guildID: plan.guildID)
            }
            _ = try await world.sendMessage(draft, as: person, in: channel, checkPermissions: false)
        case .typing:
            try await world.startTyping(person, in: channel)
        case .reaction:
            guard let message = try await world.channel(channel).messages.suffix(20).randomElement(using: &random) else { return }
            try await world.react(message.id, in: channel, by: person, emojiName: random.pick(["👍", "😂", "❤️", "🔥", "👀", "🎉", "💯"]),
                                  emojiID: nil, burst: false)
        case .edit, .delete:
            guard let message = try await world.channel(channel).messages.suffix(10).last(where: { plan.members.contains($0.authorID) })
            else { return }
            if kind == .edit {
                try await world.editMessage(message.id, in: channel, by: message.authorID,
                                            content: message.content + " " + random.pick(["(edit: typo)", "*", "!!", "lol"]), embeds: nil, flags: nil)
            } else {
                try await world.deleteMessage(message.id, in: channel, by: message.authorID)
            }
        case .presence:
            var presence = await world.presences[person] ?? Presence()
            presence.status = random.pick([.online, .online, .idle, .dnd, .offline])
            await world.updatePresence(person, presence)
        case .voice:
            try await moveVoice(person, plan, world, &random)
        }
    }

    private static func pickChannel(_ plan: LiveActivityPlan, _ random: inout SeededRandom) -> Snowflake {
        var pick = random.unit()
        for (index, share) in plan.shares.enumerated() {
            pick -= share
            if pick < 0 { return plan.channels[index] }
        }
        return random.pick(plan.channels)
    }

    private static func moveVoice(_ person: Snowflake, _ plan: LiveActivityPlan, _ world: World, _ random: inout SeededRandom) async throws {
        guard !plan.voiceChannels.isEmpty else { return }
        if let state = await world.voiceState(of: person), state.simulated {
            await world.leaveVoice(person)
        } else if await world.voiceState(of: person) == nil {
            let request = VoiceStateRequest(guildID: plan.guildID, channelID: random.pick(plan.voiceChannels))
            _ = try await world.updateVoiceState(person, sessionID: await world.nextHash(), request, simulated: true)
        }
    }
}
