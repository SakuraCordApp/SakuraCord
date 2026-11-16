import Foundation

// Server-membership life around the demo: invite links, the garden's server
// guide and onboarding, and a neighbourhood book club that reviews applications.
extension DemoConverter {
    static let bookClubInvite = "riversidereads"

    mutating func buildServerExtras() async throws {
        guard let porch = guildKeys.first(where: { $0.value == "porch" })?.key,
              let garden = guildKeys.first(where: { $0.value == "garden" })?.key else { return }
        let porchOwner = try await world.guild(porch).ownerID, gardenOwner = try await world.guild(garden).ownerID
        await addInvite("porchlight", guild: porch, channel: channels["general"], inviter: porchOwner, created: -30, maxAge: 0)
        await addInvite("lindenstreet", guild: garden, channel: channels["garden-chat"], inviter: gardenOwner, created: -90, maxAge: 0)
        await world.setServerState { $0.brandColors[porch] = "#e07a5f" }
        await addGardenGuide(garden)
        await addEvents(porch: porch, garden: garden)
        // The garden keeps weedkiller talk out of chat.
        let rule = AutoModRule(id: await world.nextID(), guildID: garden, creatorID: people["marisol"] ?? gardenOwner, name: "No weedkiller",
                               keywords: ["roundup", "*glyphosate*", "weedkiller"])
        await world.setServerState { $0.autoModRules[rule.id] = rule }
        if let pip = people["pip"] { await world.setServerState { $0.oauthRedirects[pip] = ["https://pip.example.net/discord/callback"] } }
        try await buildBookClub()
    }

    /// Thursday's game night in the porch's voice channel (Wren already acknowledged it)
    /// and the garden's planting day, announced an hour ago and still unread.
    private func addEvents(porch: Snowflake, garden: Snowflake) async {
        guard let couch = channels["couch-vc"], let nico = people["nico"], let marisol = people["marisol"], let me = people[DemoContent.selfKey]
        else { return }
        let hour = 3_600.0
        var gameNight = ScheduledEvent(id: await world.nextID(at: world.epoch.addingTimeInterval(-50 * hour)), guildID: porch,
                                       name: "Board game night", creatorID: nico,
                                       start: world.epoch.addingTimeInterval(94 * hour), entityType: .voice)
        gameNight.description = "Bring snacks. Wingspan if the birthday frog allows it."
        gameNight.channelID = couch
        gameNight.interested = [nico, me] + ["oskar", "hana"].compactMap { people[$0] }
        var planting = ScheduledEvent(id: await world.nextID(at: world.epoch.addingTimeInterval(-hour)), guildID: garden,
                                      name: "Spring planting day", creatorID: marisol,
                                      start: world.epoch.addingTimeInterval(132.5 * hour), entityType: .external)
        planting.description = "Seedlings go in the long beds. Gloves and tea provided."
        planting.end = planting.start.addingTimeInterval(3 * hour)
        planting.location = "Linden Street Garden, north gate"
        planting.interested = [marisol] + ["kofi", "ada"].compactMap { people[$0] }
        await world.setServerState { [gameNight, planting] state in
            state.scheduledEvents[gameNight.id] = gameNight
            state.scheduledEvents[planting.id] = planting
            state.eventAcks[me, default: [:]][porch] = gameNight.id
        }
    }

    private func addInvite(_ code: String, guild: Snowflake, channel: Snowflake?, inviter: Snowflake, created days: Int, maxAge: Int) async {
        guard let channel else { return }
        let created = world.epoch.addingTimeInterval(Double(days) * 86_400)
        let invite = Invite(id: await world.nextID(at: created), code: code, guildID: guild, channelID: channel, inviterID: inviter,
                            createdAt: created, maxAge: maxAge, uses: 3)
        await world.setServerState { $0.invites[code] = invite }
    }

    private func addGardenGuide(_ garden: Snowflake) async {
        guard let chat = channels["garden-chat"], let rules = channels["garden-rules"], let rota = channels["watering-rota"],
              let diary = channels["plot-diary"], let owner = await world.guilds[garden]?.ownerID else { return }
        let guide = JSONObject([
            ("enabled", true),
            ("welcome_message", .object(JSONObject([
                ("author_ids", [owner.json]),
                ("message", "Welcome to the garden, [@username]! Say hi in chat, check the watering rota, and grab a trowel."),
            ]))),
            ("new_member_actions", .array([
                Self.action(chat, type: 1, "Say hello to your neighbours"),
                Self.action(rota, type: 0, "Pick a watering day"),
                Self.action(diary, type: 0, "See what's growing"),
            ])),
            ("resource_channels", .array([.object(JSONObject([
                ("channel_id", rules.json), ("title", "Garden rules"), ("description", "Plot etiquette, tools and the compost code."),
            ]))])),
        ])
        let roleIDs = await world.guilds[garden]?.roles.filter { ["Plot Holders", "Compost Crew"].contains($0.name) }.map(\.id) ?? []
        let optionIDs = [await world.nextID(), await world.nextID()]
        let prompt: JSON = .object(JSONObject([
            ("id", await world.nextID().json), ("title", "What brings you to the garden?"),
            ("options", .array(zip(["I have a plot", "I want to help with compost"], ["🌱", "🪱"]).enumerated().map { index, option in
                .object(JSONObject([
                    ("id", optionIDs[index].json), ("title", .string(option.0)), ("description", ""),
                    ("emoji", .object(JSONObject([("id", .null), ("name", .string(option.1)), ("animated", false)]))),
                    ("role_ids", .array(roleIDs.dropFirst(index).prefix(1).map(\.json))), ("channel_ids", [diary.json]),
                ]))
            })),
            ("single_select", false), ("required", false), ("in_onboarding", true), ("type", 0),
        ]))
        let onboarding = JSONObject([("prompts", [prompt]), ("default_channel_ids", [chat.json, rules.json, rota.json]),
                                     ("enabled", true), ("mode", 0)])
        await world.setServerState { state in
            state.guides[garden] = guide
            state.onboarding[garden] = onboarding
            state.traits[garden] = [Self.trait("🌻", "Gardening", 0), Self.trait("🐝", "Beekeeping", 1), Self.trait("♻️", "Composting", 2)]
            state.brandColors[garden] = "#6bbf59"
        }
    }

    /// A small club Wren isn't in yet; joining means applying.
    private mutating func buildBookClub() async throws {
        let members = ["hana", "ada", "felix"].compactMap { people[$0] }
        guard let owner = members.first else { return }
        let founded = world.epoch.addingTimeInterval(-160 * 86_400)
        let guildID = await world.nextID(at: founded)
        var guild = Guild(id: guildID, name: "Riverside Readers", ownerID: owner)
        guild.description = "A neighbourhood book club. One book a month, tea always."
        guild.icon = builder.hash(seed: 0xb00c)
        await world.setPalette(5, forHash: guild.icon!)
        guild.features = ["COMMUNITY", "MEMBER_VERIFICATION_GATE_ENABLED", "MEMBER_VERIFICATION_MANUAL_APPROVAL"]
        guild.verificationLevel = 1
        guild.roles = [WorldBuilder.everyoneRole(guildID: guildID)]
        for (index, member) in members.enumerated() {
            guild.members[member] = Member(userID: member, joinedAt: founded.addingTimeInterval(Double(index) * 3_600))
            guild.memberOrder.append(member)
        }
        let general = Channel(id: await world.nextID(at: founded), type: .text, guildID: guildID, name: "book-chat")
        let rules = Channel(id: await world.nextID(at: founded), type: .text, guildID: guildID, name: "rules")
        guild.systemChannelID = general.id
        guild.rulesChannelID = rules.id
        await world.addGuild(guild)
        await world.addChannel(rules)
        await world.addChannel(general)
        let form = JSONObject([
            ("version", World.timestamp(founded)), ("description", .null),
            ("form_fields", [
                Self.field("TEXT_INPUT", "What's the last book you loved?"),
                Self.field("MULTIPLE_CHOICE", "Which meeting can you usually make?", extra: ("choices", ["Weekday evening", "Weekend morning"])),
                Self.field("TERMS", "Read and agree to the club rules", extra: ("values", [
                    "Be kind about other people's taste in books.", "Mark spoilers until the meeting.",
                ])),
            ]),
        ])
        await world.setServerState { state in
            state.verificationForms[guildID] = form
            state.brandColors[guildID] = "#3d7ea6"
        }
        await addInvite(Self.bookClubInvite, guild: guildID, channel: general.id, inviter: owner, created: -12, maxAge: 0)
    }

    private static func action(_ channel: Snowflake, type: Int, _ title: String) -> JSON {
        .object(JSONObject([("channel_id", channel.json), ("action_type", .int(type)), ("title", .string(title)), ("description", "")]))
    }

    private static func trait(_ emoji: String, _ label: String, _ position: Int) -> JSON {
        .object(JSONObject([("emoji_id", .null), ("emoji_name", .string(emoji)), ("emoji_animated", false),
                            ("label", .string(label)), ("position", .int(position))]))
    }

    private static func field(_ type: String, _ label: String, extra: (String, JSON)? = nil) -> JSON {
        var object = JSONObject([("field_type", .string(type)), ("label", .string(label)), ("description", .null),
                                 ("automations", .null), ("required", true)])
        if let extra { object[extra.0] = extra.1 } else { object["placeholder"] = .null }
        return .object(object)
    }
}

extension World {
    func setServerState(_ change: (inout ServerState) -> Void) { change(&servers) }
}
