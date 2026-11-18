import Foundation

// "Linden Street Garden": a neighbourhood community garden at boost level 3,
// so animated icon, banner, splash, vanity URL and role icons all show.
extension DemoContent {
    static let garden = DemoGuild(
        key: "garden", name: "Linden Street Garden",
        description: "Community garden on Linden Street. Plots, compost, bees and good company 🌻",
        icon: DemoImageStyle(seed: 0x6a2d, palette: 2, animated: true, art: .drawing(.sunflower, background: 0x2e7d32)), banner: DemoImageStyle(seed: 0x6a2e, palette: 7),
        splash: DemoImageStyle(seed: 0x6a2f, palette: 4), owner: "marisol", vanityCode: "lindenstreet", boostCount: 15,
        roles: [
            DemoRole("coordinators", "Coordinators", color: 0xf4a261, hoist: true, permissions: .admin, icon: "🌻"),
            DemoRole("garden-pip", "Pip", color: 0x56c1c1, permissions: .bot, managed: .bot("pip")),
            DemoRole("beekeepers", "Beekeepers", color: 0xe9b824, hoist: true, mentionable: true, permissions: .moderator, icon: "🐝"),
            DemoRole("plot-holders", "Plot Holders", color: 0x6bbf59, hoist: true, icon: "🌱"),
            DemoRole("compost-crew", "Compost Crew", color: 0x8c5a3c, mentionable: true, icon: "🪱"),
            DemoRole("garden-booster", "Server Booster", color: 0xf47fff, managed: .premiumSubscriber),
        ],
        members: [
            DemoMember("marisol", roles: ["coordinators", "plot-holders", "garden-booster"], joined: at(-700, 9, 0), boostingSince: at(-300, 9, 0)),
            DemoMember("kofi", roles: ["beekeepers", "plot-holders", "garden-booster"], joined: at(-650, 12, 0), boostingSince: at(-150, 18, 0)),
            DemoMember("ada", nickname: "Ada (plot 14)", roles: ["plot-holders", "compost-crew"], joined: at(-400, 15, 20)),
            DemoMember("wren", nickname: "Wren (plot 7)", roles: ["plot-holders", "garden-booster"], joined: at(-200, 11, 30), boostingSince: at(-6, 9, 58)),
            DemoMember("hana", roles: ["plot-holders"], joined: at(-180, 16, 0)),
            DemoMember("felix", roles: ["compost-crew"], joined: at(-120, 8, 0)),
            DemoMember("rosa", joined: at(-2, 11, 0)),
            DemoMember("pip", roles: ["garden-pip"], joined: at(-600, 10, 0)),
        ],
        emojis: [
            DemoCustomEmoji("busybee", .bee, seed: 0xbee, animated: true),
            DemoCustomEmoji("sprout", .leaf, seed: 0x5920),
            DemoCustomEmoji("sunflower", .flower, seed: 0x5f10),
            DemoCustomEmoji("raindrop", .drop, seed: 0x2a1d),
            DemoCustomEmoji("goodsoil", .smile, seed: 0x5011),
            DemoCustomEmoji("sunny", .sun, seed: 0x5099),
        ],
        stickers: [
            DemoSticker("Happy Sprout", description: "a sprout having a great day", tags: "🌱", format: .png, media: .sticker(seed: 0x5921, motif: .leaf)),
            DemoSticker("Bee Dance", description: "waggle waggle", tags: "🐝", format: .gif, media: .animation(seed: 0xbef, motif: .bee)),
        ],
        categories: [
            DemoCategory("garden-info", "Notice Board", [gardenNotice, gardenRules]),
            DemoCategory("garden-main", "The Garden", [gardenChat, gardenDiary, gardenSeeds, gardenRota]),
            DemoCategory("garden-events", "Gatherings", [
                DemoChannel("garden-meeting", "Monthly Meeting", kind: .stage, topic: "compost, the shed sign, spring bed results",
                            voiceStates: [DemoVoiceState("marisol"), DemoVoiceState("ada", muted: true)]),
                DemoChannel("garden-shed", "The Shed", kind: .voice,
                            voiceStates: [DemoVoiceState("kofi", camera: true), DemoVoiceState("felix")]),
            ]),
        ],
        systemChannel: "garden-chat", rulesChannel: "garden-rules"
    )

    static let gardenNotice = DemoChannel("garden-notice", "notice-board", kind: .announcement, topic: "news from the garden 🌻", messages: [
        Msg("marisol", at(-13, 9, 0), "@everyone plot rotation for next season is up. check the list on the shed door, or ask me 💛"),
        Msg("marisol", at(-6, 18, 0), """
        ## 🌱 Free seedlings, <day:0:L> 10–12
        we over-sowed (again). tomatoes, basil, chard, marigolds.
        bring a box, take what you'll love. neighbours very welcome!
        """, label: "seedlings", reactions: [React(":sprout:", "ada", "kofi", "wren", "hana")],
          attachments: [.photo("seedlings-table.jpg", seed: 0x5eee, .garden, alt: "Trays of seedlings on a long table in the garden")]),
        Msg("kofi", at(-4, 12, 0), "honey harvest is in! 🍯 jars at the shed on <day:0:l>, pay what you like, it all goes to the new water butt",
          reactions: [React("🍯", "marisol", "ada", "wren"), React(":busybee:", "hana")],
          attachments: [.photo("honey.jpg", seed: 0x401e, .food, alt: "Jars of golden honey lined up on a shelf")]),
        Msg("marisol", at(-1, 19, 30), "Monthly meeting <t:3@19:00:F> on the stage (or in person at the shed). Agenda: compost, the new shed sign (thank you <@wren>!) and the spring bed."),
        Msg("marisol", at(0, 13, 0), "seedling day: 140 plants found new homes 💚 thank you all", reactions: [React("💚", "kofi", "ada", "wren", "felix", "rosa")]),
    ])

    static let gardenRules = DemoChannel("garden-rules", "rules", topic: "the short version", messages: [
        Msg("marisol", at(-60, 10, 0), """
        1. Water what you plant.
        2. Return tools to the shed.
        3. Compost: greens and browns only. No meat, no dairy.
        4. Bees have right of way 🐝
        5. Share the harvest when you can.
        """, label: "rules", pinned: true),
    ])

    static let gardenChat = DemoChannel("garden-chat", "chat", topic: "everything garden (and beyond)", messages: [
        Msg("marisol", at(-13, 8, 0), "morning all. frost forecast tonight, cover anything tender ❄️"),
        Msg("ada", at(-13, 8, 30), "Thank you dear. Covered my dahlias with an old bedsheet. They look like little ghosts.", reactions: [React("👻", "marisol", "kofi")]),
        Msg("kofi", at(-12, 17, 0), "bees are calm today. they know the frost's coming"),
        Msg("wren", at(-11, 10, 30), "hi all! new on plot 7 🌱 i know nothing but i'm enthusiastic", reactions: [React(":sprout:", "marisol", "ada", "kofi")]),
        Msg("ada", at(-11, 10, 40), "Welcome! I'm on plot 14, right next to you. I have far too many courgettes and will be giving you some whether you like it or not."),
        Msg("wren", at(-11, 10, 41), "i will gladly accept courgettes"),
        Msg("ada", at(-11, 10, 42), "You say that now.", label: "saynow"),
        Msg("felix", at(-10, 8, 0), "<@&compost-crew> the bins are full again. turning them <day:-8:l> morning if anyone wants a workout"),
        Msg("marisol", at(-10, 8, 10), "thank you felix 💚"),
        Msg("kofi", at(-9, 15, 0), "PSA: if you see a swarm, don't panic, call me. they're just house hunting"),
        Msg("hana", at(-8, 11, 0), "is it ok to bring miso to the garden or will she terrorise the bees"),
        Msg("kofi", at(-8, 11, 10), "the bees will be fine. can't speak for miso"),
        Msg("ada", at(-7, 16, 0), "The courgettes have begun.",
          attachments: [.photo("courgettes.jpg", seed: 0xc062, .garden, alt: "A garden bed overflowing with courgette plants")]),
        Msg("wren", at(-7, 16, 5), "ada that's like nine courgettes"),
        Msg("ada", at(-7, 16, 5), "Eleven.", reactions: [React("😂", "marisol", "kofi", "wren")]),
        Msg("wren", at(-6, 9, 58), reactions: [React("🎉", "marisol", "ada", "kofi"), React(":busybee:", "kofi")], system: .boostTier(3)),
        Msg("marisol", at(-4, 19, 0), "spring shared bed, cast your votes! you can pick more than one", label: "springpoll",
          poll: DemoPoll("What should we grow in the shared bed?", multiselect: true, hours: 72, finalized: true, [
              DemoPollAnswer("Wildflowers for the bees", emoji: "🌼", voters: ["kofi", "wren", "marisol", "hana"]),
              DemoPollAnswer("Pumpkins", emoji: "🎃", voters: ["ada", "kofi", "felix"]),
              DemoPollAnswer("Strawberries", emoji: "🍓", voters: ["hana", "wren"]),
              DemoPollAnswer("Sunflowers", emoji: ":sunflower:", voters: ["ada", "marisol"]),
          ])),
        Msg("rosa", at(-2, 11, 0), reactions: [React("👋", "marisol", "wren")], system: .memberJoin),
        Msg("marisol", at(-2, 11, 5), "welcome rosa! 🌻 you drew the bee mural sketch at the open day, right?"),
        Msg("rosa", at(-2, 11, 10), "that's me! still hoping the shed wall says yes 🐝"),
        Msg("marisol", at(-1, 19, 0), system: .pollResult("springpoll")),
        Msg("kofi", at(-1, 19, 5), "wildflowers it is. the bees thank you <a:busybee:>"),
        Msg("ada", at(0, 10, 30), "Wren dear, I left a courgette on your plot. Just one. For now.", label: "courgette",
          reactions: [React("😂", "wren", "marisol")], stickers: ["Happy Sprout"]),
        Msg("wren", at(0, 10, 45), "ada i see THREE courgettes", replyTo: "courgette"),
        Msg("ada", at(0, 10, 46), "They multiply when you're not looking.", replyTo: "saynow", reactions: [React("🥒", "kofi", "marisol", "hana")]),
    ])

    static let gardenDiary = DemoChannel("plot-diary", "plot-diary", topic: "photos from your plot, any season", messages: [
        Msg("marisol", at(-12, 15, 0), "plot 1, late season. the chard refuses to quit",
          attachments: [.photo("chard.jpg", seed: 0xc4a2, .garden, alt: "Rainbow chard in a raised bed")]),
        Msg("kofi", at(-11, 13, 0), "hive check ✅ queen spotted, very regal", reactions: [React(":busybee:", "marisol", "ada")],
          attachments: [.photo("hives.jpg", seed: 0x41fe, .landscape, alt: "Two beehives at the edge of a meadow")]),
        Msg("wren", at(-10, 17, 0), "plot 7, day 1. it's mostly rhubarb and hope",
          attachments: [.photo("plot7-day1.jpg", seed: 0x9071, .garden, alt: "A weedy garden plot with a large rhubarb plant")]),
        Msg("ada", at(-9, 9, 0), "The dahlias survived the frost! The ghosts worked.",
          attachments: [.photo("dahlias.jpg", seed: 0xda11, .plant, width: 960, height: 1_280, alt: "Pink dahlias in a clay pot")]),
        Msg("hana", at(-6, 16, 0), "my tiny herb corner 🌿", attachments: [.photo("herbs.jpg", seed: 0x4e2b, .plant, alt: "Basil and thyme growing in small pots")]),
        Msg("wren", at(-4, 17, 30), "plot 7, day 7: weeded. found a frog. named him nico jr 🐸", label: "frog",
          attachments: [.photo("plot7-day7.jpg", seed: 0x9077, .garden, alt: "A tidy garden plot with fresh soil")]),
        Msg("ada", at(-4, 17, 45), "A frog is very good luck for a garden.", replyTo: "frog"),
        Msg("felix", at(-3, 10, 0), "compost bins turned 💪 biscuit supervised",
          attachments: [.photo("supervisor.jpg", seed: 0xb15e, .dog, alt: "Biscuit the dog sitting next to the compost bins")]),
        Msg("marisol", at(0, 14, 0), "seedling day leftovers. marigolds are up for grabs, just take them",
          attachments: [.photo("marigolds.jpg", seed: 0x3a29, .garden, alt: "Leftover marigold seedlings in trays")]),
    ])

    static let gardenRota = DemoChannel("watering-rota", "watering-rota", topic: "who's watering this week 💧", messages: [
        Msg("pip", at(-7, 9, 0), label: "rota",
          embeds: [DemoEmbed(
              .rich, title: "💧 Watering Rota", description: "The next four weeks. Pick a week below, or swap with someone.",
              color: 0x4fb3e8, authorName: "Pip", authorIcon: "pip", footer: "Pip · rota updates every Monday", footerIcon: "pip",
              fields: [
                  DemoEmbedField("Week 1", "<@ada> & <@wren>"), DemoEmbedField("Week 2", "<@kofi>"),
                  DemoEmbedField("Week 3", "<@felix> & <@hana>"), DemoEmbedField("Week 4", "*open*"),
              ]
          )],
          components: [
              DemoActionRow([.select(customID: "rota:week", placeholder: "Pick your watering week", options: [
                  DemoSelectOption("Week 1", value: "1", description: "ada & wren", emoji: "1️⃣"),
                  DemoSelectOption("Week 2", value: "2", description: "kofi", emoji: "2️⃣"),
                  DemoSelectOption("Week 3", value: "3", description: "felix & hana", emoji: "3️⃣"),
                  DemoSelectOption("Week 4", value: "4", description: "nobody yet!", emoji: ":raindrop:"),
              ])]),
              DemoActionRow([
                  .button(label: "Swap with someone", style: .secondary, emoji: "🔁", customID: "rota:swap"),
                  .button(label: "Rota guide", style: .link, url: "https://lindenstreet.garden/rota"),
              ]),
          ]),
        Msg("ada", at(-7, 9, 30), "I'll take week 4 as well. The courgettes need me."),
        Msg("pip", at(-7, 9, 31), "✅ <@ada> is now on **week 4**.", replyTo: "rota", interaction: DemoInteraction("ada", "rota join")),
        Msg("wren", at(-1, 18, 0), "watered plot 7 and the shared beds 💧 the rhubarb looks smug"),
        Msg("pip", at(0, 7, 0), "💧 Morning! It's <@ada> and <@wren>'s watering week. Rain forecast <t:2@6:00:R>, so you can skip that one <:raindrop:>"),
    ])

    static let gardenSeeds = DemoChannel(
        "seed-library", "seed-library", kind: .forum, topic: "swap seeds, cuttings and tubers",
        forumTags: [DemoForumTag("offering", emoji: "🎁"), DemoForumTag("looking for", emoji: "🔍"), DemoForumTag("swapped", emoji: "🤝", moderated: true)],
        posts: [
            DemoForumPost("Offering: dahlia tubers (lots)", tags: ["offering"], [
                Msg("ada", at(-9, 10, 0), "Dividing my dahlias. Pinks and deep reds. Free to good homes."),
                Msg("hana", at(-9, 10, 30), "i'd love a pink one!"),
                Msg("ada", at(-9, 10, 45), "I'll leave one by the shed with your name on it."),
            ]),
            DemoForumPost("Looking for: sweet pea seeds", tags: ["looking for", "swapped"], [
                Msg("wren", at(-5, 11, 0), "want to grow them up the plot 7 fence. any colour"),
                Msg("marisol", at(-5, 11, 20), "I have a packet of the old purple ones that smell amazing"),
                Msg("wren", at(-5, 11, 21), "yes please!!", reactions: [React(":sunflower:", "marisol")]),
            ]),
            DemoForumPost("Offering: comb honey for seeds", tags: ["offering"], [
                Msg("kofi", at(-3, 13, 0), "trading small jars of comb honey for any interesting seeds. surprise me 🐝"),
                Msg("rosa", at(-1, 16, 0), "i have chilli seeds from my grandmother's garden. very hot. is that interesting enough?"),
                Msg("kofi", at(-1, 16, 20), "that's the most interesting thing anyone's ever offered me"),
            ]),
        ]
    )
}
