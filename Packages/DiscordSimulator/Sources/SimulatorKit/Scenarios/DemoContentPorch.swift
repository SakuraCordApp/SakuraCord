import Foundation

// "The Porch": a small server of friends. Running threads through the two
// weeks: Tomás moves (and the couch might not fit), Priya's exams, June's half
// marathon, Oskar's broken bike, the band's café gig, Miso the cat's crimes,
// Wren's monstera Gerald, Lou's trip and Nico's birthday.
extension DemoContent {
    static let porch = DemoGuild(
        key: "porch", name: "The Porch", description: "friends, snacks, and whatever's going on 🏡",
        icon: DemoImageStyle(seed: 0x9024, palette: 4, art: .drawing(.house, background: 0x3e2a47)), owner: "wren", boostCount: 4,
        roles: [
            DemoRole("keyholders", "Keyholders", color: 0xe0a458, hoist: true, permissions: .admin),
            DemoRole("porch-lights", "Porch Lights", color: 0xf2c14e, hoist: true, permissions: .moderator),
            DemoRole("pip", "Pip", color: 0x56c1c1, permissions: .bot, managed: .bot("pip")),
            DemoRole("band", "Quiet Neighbours", color: 0x6c7bbf, hoist: true, mentionable: true),
            DemoRole("runners", "Runners", color: 0x52b788, mentionable: true),
            DemoRole("gamers", "Board Gamers", color: 0xa98bd6, mentionable: true),
            DemoRole("booster", "Server Booster", color: 0xf47fff, managed: .premiumSubscriber),
        ],
        members: [
            DemoMember("wren", roles: ["keyholders", "gamers", "runners", "booster"], joined: at(-400, 10, 0), boostingSince: at(-200, 12, 0)),
            DemoMember("tomas", roles: ["porch-lights", "gamers", "booster"], joined: at(-399, 18, 20), boostingSince: at(-90, 9, 0)),
            DemoMember("hana", roles: ["porch-lights", "gamers"], joined: at(-399, 19, 2)),
            DemoMember("priya", roles: ["gamers"], joined: at(-398, 21, 45)),
            DemoMember("june", roles: ["runners"], joined: at(-390, 7, 15)),
            DemoMember("oskar", nickname: "oskar 🎸", roles: ["band", "gamers"], joined: at(-380, 22, 0)),
            DemoMember("sam", roles: ["band"], joined: at(-380, 22, 5)),
            DemoMember("rafi", nickname: "Mr. Hm", roles: ["porch-lights"], joined: at(-300, 17, 30)),
            DemoMember("lou", roles: ["booster"], joined: at(-350, 8, 10), boostingSince: at(-12, 7, 58)),
            DemoMember("nico", nickname: "nico 🐸", roles: ["gamers"], joined: at(-250, 20, 0)),
            DemoMember("felix", roles: ["runners"], joined: at(-10, 10, 1)),
            DemoMember("pip", roles: ["pip"], joined: at(-395, 10, 30)),
        ],
        emojis: [
            DemoCustomEmoji("froggo", .frog, seed: 0xf20),
            DemoCustomEmoji("miso", .cat, seed: 0x3150),
            DemoCustomEmoji("gerald", .leaf, seed: 0x6e2a),
            DemoCustomEmoji("couch", .couch, seed: 0xc0c4),
            DemoCustomEmoji("porchlove", .heart, seed: 0x1047, animated: true),
            DemoCustomEmoji("pipwave", .sparkle, seed: 0x919e, animated: true),
        ],
        stickers: [
            DemoSticker("Miso Loaf", description: "Miso in her natural loaf form", tags: "🐈", format: .png, media: .sticker(seed: 0x3151, motif: .cat)),
            DemoSticker("Pip Pulse", description: "Pip says hello", tags: "✨", format: .apng, media: .bundled("demo-sticker.apng")),
            DemoSticker("Froggo Dance", description: "a very happy frog", tags: "🐸", format: .gif, media: .animation(seed: 0xf21, motif: .frog)),
        ],
        categories: [
            DemoCategory("porch-info", "Info", [porchAnnouncements]),
            DemoCategory("porch-front", "Front Porch", [porchGeneral, porchKitchen, porchPets, porchRecs, porchTravel]),
            DemoCategory("porch-clubs", "Clubs", [porchRunning, porchBand, porchStudy, porchForum]),
            DemoCategory("porch-voice", "Hang Out", [
                DemoChannel("couch-vc", "The Couch", kind: .voice, voiceStates: [
                    DemoVoiceState("hana"), DemoVoiceState("nico", muted: true), DemoVoiceState("oskar", streaming: true),
                ]),
                DemoChannel("study-vc", "Study Room", kind: .voice, voiceStates: [DemoVoiceState("sam", muted: true)], userLimit: 4),
            ]),
        ],
        systemChannel: "general", rulesChannel: "announcements"
    )

    // MARK: #announcements

    static let porchAnnouncements = DemoChannel("announcements", "announcements", kind: .announcement,
                                                topic: "the important stuff. Keyholders post, everyone reads 💛", messages: [
        Msg("wren", at(-13, 10, 0), """
        **Welcome to the Porch** 🏡

        quick tour:
        - <#general> for everything
        - <#kitchen> for food (photos mandatory)
        - <#pets> for creatures of all kinds
        - <#running> for june and the people june has convinced
        - <#band-room> for Quiet Neighbours business
        - <#ask-the-porch> when you need a drill, a ladder or advice

        be kind, share snacks 💛
        """, label: "welcome", reactions: [React(":porchlove:", "tomas", "hana", "june", "nico", "sam")], pinned: true),
        Msg("wren", at(-13, 10, 1), system: .pinned("welcome")),
        Msg("pip", at(-13, 18, 0), embeds: [digest(week: 1, top: "Tomás signed a lease 🔑", newFaces: "nobody yet", next: "Game night (Thu) · June's half (Sun)", at: at(-13, 18, 0))]),
        Msg("wren", at(-10, 10, 15), "@everyone please welcome <@felix> (and Biscuit, his dog, who is the real member here) 🐕",
          reactions: [React("👋", "june", "hana", "tomas", "rafi"), React("🐕", "nico")]),
        Msg("wren", at(-9, 16, 0), system: .channelFollowAdded("Linden Street Garden #notice-board")),
        Msg("wren", at(-6, 9, 30), """
        ## Move day crew 📦
        **Saturday, 9am** at Tomás's old place.
        1. bring gloves
        2. bring snacks
        3. do *not* bring opinions about the couch

        __lunch is on tomás__ — ~~pizza~~ dumplings, the people have spoken
        """, label: "moveday", reactions: [React("📦", "tomas", "oskar", "rafi"), React(":couch:", "sam", "hana")], edited: 3_100),
        Msg("pip", at(-6, 18, 0), embeds: [digest(week: 2, top: "June's sub-2 half marathon 🏅", newFaces: "<@felix> and Biscuit", next: "Move day (Sat) · café gig (Fri)", at: at(-6, 18, 0))]),
        Msg("wren", at(-2, 12, 5), "@here Quiet Neighbours play the Corner Café **tonight at 8** 🎸 go be loud for them",
          reactions: [React("🎸", "hana", "tomas", "june", "nico"), React("🥁", "priya")]),
        Msg("pip", at(0, 18, 0), embeds: [digest(week: 3, top: "The couch fit 🛋️", newFaces: "none, but Nico is a year older", next: "Game night (Thu) · pancakes at Tomás's (Sat)", at: at(0, 18, 0))]),
    ])

    static func digest(week: Int, top: String, newFaces: String, next: String, at time: DemoTime) -> DemoEmbed {
        DemoEmbed(
            .rich, title: "🏡 Porch Digest · week \(week)", description: "Here's what happened on the porch this week.",
            color: 0xf2c14e, authorName: "Pip", authorIcon: "pip", footer: "Pip · weekly digest", footerIcon: "pip",
            fields: [
                DemoEmbedField("🔥 Most reactions", top, inline: false),
                DemoEmbedField("👋 New faces", newFaces),
                DemoEmbedField("📅 Coming up", next),
            ],
            timestamp: time
        )
    }

    static func gameNight(on day: Int, rsvps: String, games: String) -> DemoEmbed {
        DemoEmbed(
            .rich, title: "🎲 Board Game Night", description: "Hosted at Wren's. Bring snacks, not rules disputes.",
            color: 0xa98bd6, authorName: "Pip's Game Night", authorIcon: "pip",
            footer: "Use the buttons to RSVP · /gamenight list", footerIcon: "pip",
            fields: [
                DemoEmbedField("When", "<t:\(day)@19:00:F> (<t:\(day)@19:00:R>)"),
                DemoEmbedField("Where", "Wren's place 🪴"),
                DemoEmbedField("On the table", games, inline: false),
                DemoEmbedField("RSVPs", rsvps, inline: false),
            ],
            thumbnail: DemoEmbedMedia(.sticker(seed: 0x6a3e, motif: .star), width: 160, height: 160)
        )
    }

    static let gameNightButtons = [
        DemoActionRow([
            .button(label: "I'm in", style: .success, emoji: "✅", customID: "gamenight:yes"),
            .button(label: "Maybe", style: .secondary, emoji: "🤔", customID: "gamenight:maybe"),
            .button(label: "Can't make it", style: .danger, customID: "gamenight:no"),
            .button(label: "House rules", style: .link, url: "https://notes.theporch.club/house-rules"),
        ]),
    ]

    // MARK: #general

    static let porchGeneral = DemoChannel("general", "general", topic: "the porch. pull up a chair ☕", unreadFrom: "catchup", messages: [
        // Day -13
        Msg("tomas", at(-13, 8, 47), "ok it's official. signed the lease 🎉🔑", label: "lease",
          reactions: [React("🎉", "wren", "june", "hana", "priya", "sam"), React("🔑", "oskar")]),
        Msg("wren", at(-13, 8, 49), "TOMÁS!!! congrats!!", replyTo: "lease"),
        Msg("hana", at(-13, 8, 52), "does the new place have an oven that works or is it another \"decorative\" oven", label: "oven"),
        Msg("tomas", at(-13, 8, 55), "it has an oven that WORKS. gas. i might cry", replyTo: "oven", reactions: [React("🥹", "hana")]),
        Msg("june", at(-13, 9, 10), "when's the move?"),
        Msg("tomas", at(-13, 9, 12), "saturday after next. so like 12 days. totally fine 🙂"),
        Msg("oskar", at(-13, 9, 30), "i can help carry stuff. i cannot help with stairs. nobody can help with stairs"),
        Msg("tomas", at(-13, 9, 31), "ground floor! the only problem is the couch", label: "couch"),
        Msg("sam", at(-13, 9, 33), "oh no. not The Couch"),
        Msg("wren", at(-13, 9, 34), "the couch has survived two moves and a flood. it will survive this"),
        Msg("tomas", at(-13, 9, 35), "the couch is 2.4m long and the new door is... let's not talk about the new door",
          reactions: [React("💀", "june", "sam"), React(":couch:", "wren", "hana")]),
        Msg("priya", at(-13, 21, 40), "sorry, just seeing this. congrats tomás!! 🥹 i'm in a flashcard cave until next wednesday but i'll come see it after"),
        // Day -12
        Msg("lou", at(-12, 7, 58), system: .boost),
        Msg("hana", at(-12, 8, 3), "lou 💖"),
        Msg("hana", at(-12, 12, 21), "PSA: miso stole a sock off the radiator and is now guarding it like treasure", label: "sock",
          reactions: [React(":miso:", "wren", "nico"), React("😂", "tomas", "june", "oskar")],
          attachments: [.photo("miso-sock.jpg", seed: 0x3152, .cat, alt: "An orange cat curled protectively around a single striped sock")]),
        Msg("nico", at(-12, 12, 24), "she's built different"),
        Msg("rafi", at(-12, 12, 30), "the sock tax is real"),
        Msg("oskar", at(-12, 19, 2), "bike update: chain snapped on the way home. walked 3km pushing it like a sad shopping trolley", label: "chain",
          reactions: [React("😭", "june"), React("🫡", "sam")]),
        Msg("rafi", at(-12, 19, 5), "bring it over sunday. i have a chain tool and a frankly unreasonable amount of spare parts", replyTo: "chain"),
        Msg("oskar", at(-12, 19, 6), "you are a saint"),
        Msg("rafi", at(-12, 19, 6), "i am a chemistry teacher with a garage. same thing", reactions: [React("😂", "oskar", "wren")]),
        // Day -11
        Msg("june", at(-11, 6, 45), "last tempo run before sunday ✅ legs are jelly but the sunrise was worth it",
          reactions: [React("🌅", "wren", "hana"), React("💪", "tomas", "oskar", "rafi")],
          attachments: [.photo("sunrise-loop.jpg", seed: 0x5e15, .landscape, alt: "Sunrise over green hills along a running path")]),
        Msg("wren", at(-11, 7, 30), "june gets up at 5 voluntarily. i will never understand"),
        Msg("june", at(-11, 7, 32), "it's the only time the path isn't full of geese"),
        Msg("sam", at(-11, 7, 33), "the geese are the real competition"),
        Msg("priya", at(-11, 13, 15), "quick question for the room: how many flashcards is too many flashcards"),
        Msg("rafi", at(-11, 13, 17), "there's no such thing as too many. there IS such a thing as too many in one deck"),
        Msg("priya", at(-11, 13, 18), "my deck is 2,800 cards"),
        Msg("rafi", at(-11, 13, 18), "ok that's too many", reactions: [React("😂", "priya", "wren", "nico")]),
        // Day -10
        Msg("felix", at(-10, 10, 1), label: "join", reactions: [React("👋", "wren", "hana", "june")], system: .memberJoin),
        Msg("wren", at(-10, 10, 2), replyTo: "join", stickers: ["Wave"]),
        Msg("june", at(-10, 10, 3), "FELIX! everyone, this is felix from running club. his dog does intervals faster than me"),
        Msg("felix", at(-10, 10, 10), "hi all 👋 biscuit says hi too. biscuit is the dog. i'm the human"),
        Msg("hana", at(-10, 10, 12), "we're going to need biscuit pics in <#pets> asap"),
        Msg("felix", at(-10, 10, 13), "say no more"),
        Msg("tomas", at(-10, 18, 40), "measured the door. it's 81cm. the couch is 92cm deep. i'm going to be sick", label: "measure",
          reactions: [React("😬", "wren", "hana", "oskar", "june"), React(":couch:", "sam")]),
        Msg("oskar", at(-10, 18, 41), "couch on its side?"),
        Msg("tomas", at(-10, 18, 42), "on its side it's 95. it's a very square couch"),
        Msg("sam", at(-10, 18, 44), "time to learn some geometry"),
        Msg("rafi", at(-10, 18, 45), "pivot"),
        Msg("oskar", at(-10, 18, 45), "PIVOT"),
        Msg("wren", at(-10, 18, 46), "PIVOOOOT", label: "pivot", reactions: [React("😂", "tomas", "sam", "june", "hana", "nico")]),
        Msg("wren", at(-10, 23, 12), "game night report: the bird game ended in a four-way tie. never seen anything like it"),
        Msg("nico", at(-10, 23, 20), "rematch next week. i'll be training", label: "training"),
        // Day -9
        Msg("lou", at(-9, 6, 12), "airport ✈️ see you in a week, behave", reactions: [React("✈️", "wren", "hana", "tomas", "june")]),
        Msg("hana", at(-9, 6, 30), "bring back pastéis de nata or don't come back"),
        Msg("lou", at(-9, 6, 31), "deal"),
        Msg("wren", at(-9, 14, 2), "GERALD HAS A NEW LEAF. it's still rolled up but it's THERE", label: "gerald",
          reactions: [React(":gerald:", "hana", "sam", "nico", "priya"), React("🌱", "june")],
          attachments: [.photo("gerald-new-leaf.jpg", seed: 0x6e2b, .plant, width: 960, height: 1_280, alt: "A monstera in a terracotta pot with a new leaf just starting to unroll")]),
        Msg("sam", at(-9, 14, 5), "go gerald go"),
        Msg("priya", at(-9, 14, 20), "this is the content i needed between cardiology and renal"),
        Msg("oskar", at(-9, 20, 15), "<@&band> practice moved to tuesday, sam's got a late shift monday"),
        // Day -8
        Msg("hana", at(-8, 9, 10), "miso update: she stole an entire bread roll off the cooling rack and carried it under the bed. found it this morning. untouched. just... kept",
          reactions: [React("😭", "wren"), React("🍞", "tomas", "june"), React(":miso:", "nico")]),
        Msg("tomas", at(-8, 9, 12), "she's building a pantry"),
        Msg("nico", at(-8, 9, 15), "a sock, a roll... she's working up to something", label: "workingup"),
        Msg("june", at(-8, 16, 0), "race is TOMORROW. carb loading is a lifestyle now 🍝"),
        Msg("felix", at(-8, 16, 2), "biscuit and i will be at the 15k mark with a sign"),
        Msg("june", at(-8, 16, 3), "if the sign says \"you're almost there\" i'm leaving this server"),
        Msg("felix", at(-8, 16, 4), "it says \"you smell like victory\"", reactions: [React("😂", "june", "wren", "sam", "tomas")]),
        // Day -7
        Msg("june", at(-7, 13, 20), "I DID IT. 1:58:41!!!! UNDER TWO HOURS!!!!", label: "race",
          reactions: [
              React("🎉", "wren", "tomas", "hana", "oskar", "sam", "rafi", "felix", "nico", "priya", burst: ["wren"]),
              React("🏅", "felix", "lou"), React(":froggo:", "nico"),
          ],
          attachments: [.photo("medal.jpg", seed: 0x3ed1, .medal, width: 960, height: 1_280, alt: "A gold finisher's medal on a red ribbon")]),
        Msg("felix", at(-7, 13, 22), "the sign worked"),
        Msg("wren", at(-7, 13, 23), "SUB TWO!!! JUNE!!!!!"),
        Msg("priya", at(-7, 13, 40), "crying in the library, congratulations 🥹", replyTo: "race"),
        Msg("tomas", at(-7, 13, 45), "this calls for celebratory pancakes. in my new kitchen. in 6 days"),
        Msg("june", at(-7, 13, 46), "holding you to that"),
        Msg("oskar", at(-7, 18, 20), "bike is at rafi's. he looked at it and said \"hm.\" which is the scariest thing a man with tools has ever said", label: "hm"),
        Msg("rafi", at(-7, 18, 22), "it was a positive hm", replyTo: "hm"),
        Msg("rafi", at(-7, 18, 22), "mostly", reactions: [React("😬", "oskar")]),
        // Day -6
        Msg("pip", at(-6, 9, 0), "<@&gamers> it's that time again!", label: "gamenight",
          reactions: [React("🎲", "nico", "wren", "hana")],
          embeds: [gameNight(on: -3, rsvps: "✅ Wren, Nico, Hana, Oskar · 🤔 Tomás", games: "the bird one · the train one · something new Nico found")],
          components: gameNightButtons),
        Msg("nico", at(-6, 9, 5), "clicked yes so fast i sprained something"),
        Msg("tomas", at(-6, 11, 30), "5 days until the move. the couch situation has not improved", label: "couchthread",
          thread: DemoThread("the couch situation 🛋️", [
              Msg("tomas", at(-6, 11, 31), "thread for couch logistics so we don't flood general"),
              Msg("oskar", at(-6, 11, 35), "have you considered: window"),
              Msg("tomas", at(-6, 11, 36), "the window is smaller than the door, oskar"),
              Msg("rafi", at(-6, 12, 2), "take the feet off. if they unscrew you gain ~6cm", label: "feet"),
              Msg("tomas", at(-6, 12, 3), "...the feet unscrew???", replyTo: "feet"),
              Msg("rafi", at(-6, 12, 3), "most do. look underneath"),
              Msg("tomas", at(-6, 12, 9), "THEY UNSCREW", reactions: [React("🎉", "wren", "rafi", "oskar")]),
              Msg("wren", at(-6, 12, 11), "so 95 - 6 = 89. door is 81. still 8cm"),
              Msg("sam", at(-6, 12, 15), "take the door off its hinges too. that's another 4cm"),
              Msg("tomas", at(-6, 12, 16), "still 4 short. this couch is going to make me a better person"),
              Msg("june", at(-6, 12, 20), "or we saw it in half and call it a sectional"),
              Msg("tomas", at(-6, 12, 20), "absolutely not", reactions: [React("😂", "june", "sam", "hana", "wren")]),
              Msg("tomas", at(-1, 15, 25), "update for the archive: it fit. door off, feet off, cushions out, and one deep breath. we did not have to pivot",
                reactions: [React(":couch:", "wren", "oskar", "rafi", "sam", "june", "hana", burst: ["wren"])]),
          ])),
        Msg("hana", at(-6, 12, 40), "lunch break focaccia. it's supposed to look like a garden, it looks like a garden after a storm",
          reactions: [React("🤤", "tomas", "wren", "june")],
          attachments: [.photo("focaccia.jpg", seed: 0xf0ca, .food, alt: "Focaccia topped with tomatoes, olives and herbs")]),
        Msg("priya", at(-6, 22, 15), "2 days. my brain is 40% pharmacology 60% panic", label: "panic"),
        Msg("wren", at(-6, 22, 17), "you've got this. also drink water. also sleep. in that order", replyTo: "panic"),
        Msg("priya", at(-6, 22, 18), "the order is negotiable"),
        // Day -5
        Msg("oskar", at(-5, 8, 30), "BIKE LAZARUS 🚲⚡ rafi you absolute legend", label: "lazarus",
          reactions: [React("🚲", "rafi", "wren", "sam"), React("🙌", "june", "tomas")],
          attachments: [.photo("she-lives.jpg", seed: 0xb1ce, .bike, alt: "A bicycle with a new chain leaning against a garage wall")]),
        Msg("rafi", at(-5, 8, 34), "new chain, new cassette, trued the back wheel. told you it was a positive hm", replyTo: "lazarus",
          reactions: [React("😂", "oskar", "sam", "wren")]),
        Msg("sam", at(-5, 8, 40), "the hm saga concludes"),
        Msg("june", at(-5, 12, 0), "anyone want to join a recovery jog thursday morning? like, actually slow. conversational pace. <@&runners>"),
        Msg("felix", at(-5, 12, 5), "biscuit and i are in"),
        Msg("wren", at(-5, 19, 30), forward: DemoMessageRef("garden-notice", "seedlings")),
        Msg("wren", at(-5, 19, 31), "free seedlings at the community garden sunday morning if anyone wants tomatoes for a windowsill 🍅 <a:busybee:>"),
        Msg("hana", at(-5, 19, 35), "oh i want basil"),
        Msg("tomas", at(-5, 19, 36), "i want everything for the new balcony. wait. do i have a balcony", label: "balcony"),
        Msg("tomas", at(-5, 19, 37), "i have a balcony!!", replyTo: "balcony", reactions: [React("🌿", "wren", "hana")], edited: 1),
        // Day -4
        Msg("priya", at(-4, 7, 0), "exam day. see you on the other side 🫡", label: "examday",
          reactions: [React("🍀", "wren", "hana", "june", "tomas", "sam", "rafi", "oskar", "nico"), React("💪", "felix"), React(":froggo:", "nico")]),
        Msg("nico", at(-4, 7, 5), "<:froggo:> good luck frog has been dispatched", replyTo: "examday"),
        Msg("tomas", at(-4, 18, 0), "priya how did it go??"),
        Msg("priya", at(-4, 18, 45), "i don't know. fine? i think fine? results saturday. i'm going to eat something and lie on the floor"),
        Msg("hana", at(-4, 18, 46), "the floor is a valid study tool"),
        Msg("wren", at(-4, 21, 10), "settling this democratically", label: "poll",
          poll: DemoPoll("Where are we eating after the move? 🍽️", hours: 48, finalized: true, [
              DemoPollAnswer("Dumplings", emoji: "🥟", voters: ["wren", "hana", "oskar", "sam", "rafi", "june"]),
              DemoPollAnswer("Pizza", emoji: "🍕", voters: ["tomas", "nico"]),
              DemoPollAnswer("Tacos", emoji: "🌮", voters: ["priya"]),
              DemoPollAnswer("Whatever's closest to the couch", emoji: ":couch:", voters: ["felix"]),
          ])),
        Msg("tomas", at(-4, 21, 12), "i said i'd buy PIZZA. this is a coup", replyTo: "poll"),
        Msg("sam", at(-4, 21, 13), "democracy is beautiful", reactions: [React("🥟", "wren", "hana")]),
        // Day -3
        Msg("hana", at(-3, 7, 40), "SHE DID IT. miso stole a whole croissant. off a PLATE. while i was LOOKING", label: "croissant", replyTo: "workingup",
          reactions: [React("🥐", "nico", "wren", "tomas"), React(":miso:", "june", "sam"), React("😭", "oskar")],
          attachments: [.photo("SPOILER_crime-scene.jpg", seed: 0x3153, .cat, alt: "Miso the cat sitting proudly next to a squashed croissant", spoiler: true)]),
        Msg("nico", at(-3, 7, 42), "told you. she was working up to something"),
        Msg("june", at(-3, 7, 50), "recovery jog done, everyone was very conversational. mostly about croissants"),
        Msg("oskar", at(-3, 18, 30), "game night tonight? i'm bringing the new one"),
        Msg("wren", at(-3, 23, 50), "game night report: nico won the bird game. he was NOT joking about training", label: "report", replyTo: "training",
          reactions: [React("🐸", "nico", "hana"), React(":froggo:", "nico", "oskar")]),
        Msg("nico", at(-3, 23, 52), "i read the rulebook twice. that's what training means"),
        // Day -2
        Msg("wren", at(-2, 10, 15), "GERALD'S LEAF UNFURLED 🌿 look at those holes", replyTo: "gerald",
          reactions: [React(":gerald:", "hana", "sam", "nico", "tomas", "june"), React("🌿", "priya")],
          attachments: [.photo("gerald-unfurled.jpg", seed: 0x6e2c, .plant, width: 960, height: 1_280, alt: "A monstera with a big new split leaf fully open")]),
        Msg("sam", at(-2, 10, 20), "proud of him"),
        Msg("oskar", at(-2, 12, 0), "reminder: we're playing the corner café tonight 8pm, come say hi 🎸 setlist's in <#band-room>"),
        Msg("hana", at(-2, 12, 2), "front row"),
        Msg("wren", at(-2, 21, 10), system: .pollResult("poll")),
        Msg("tomas", at(-2, 23, 30), "quiet neighbours were NOT quiet. incredible. my ears are ringing",
          reactions: [React("🔥", "wren", "hana", "june", "nico"), React("🎸", "lou")]),
        Msg("sam", at(-2, 23, 35), "we had ONE job (being quiet) and we failed beautifully"),
        // Day -1
        Msg("tomas", at(-1, 7, 30), "MOVE DAY. van's here. coffee's on. couch is nervous",
          reactions: [React("📦", "wren", "oskar", "rafi"), React(":couch:", "sam", "hana")]),
        Msg("priya", at(-1, 9, 5), "# I PASSED 🎉\nall of it. every station. going back to bed", label: "passed",
          reactions: [
              React("🎉", "wren", "tomas", "hana", "june", "oskar", "sam", "rafi", "lou", "nico", "felix", burst: ["wren"]),
              React("🥹", "wren", "hana"), React(":porchlove:", "wren"),
          ], pinned: true),
        Msg("wren", at(-1, 9, 6), system: .pinned("passed")),
        Msg("wren", at(-1, 9, 6), "this is going on the pinboard forever"),
        Msg("june", at(-1, 9, 7), "PRIYA!!!!!! 🥳🥳"),
        Msg("rafi", at(-1, 9, 10), "Dr. Priya (soon) 🩺"),
        Msg("priya", at(-1, 9, 12), "-# not a doctor yet but i'll allow it"),
        Msg("oskar", at(-1, 11, 40), "rode the bike to the move. zero incidents. lazarus is thriving", replyTo: "lazarus"),
        Msg("tomas", at(-1, 15, 20), "IT'S IN", label: "itsin",
          reactions: [React("🛋️", "wren", "oskar", "rafi", "sam", "june", "hana", burst: ["wren"]), React(":couch:", "nico")],
          attachments: [.photo("its-in.jpg", seed: 0xc0c5, .couch, alt: "A green couch inside a living room next to a doorway with the door taken off")]),
        Msg("tomas", at(-1, 15, 21), "full story in the thread. we did not have to pivot", replyTo: "pivot"),
        Msg("hana", at(-1, 19, 30), "dumplings were perfect and tomás's new place is SO nice"),
        Msg("tomas", at(-1, 19, 45), "thank you all so much. seriously. pancakes next saturday, everyone's invited 🥞",
          reactions: [React("❤️", "wren", "hana", "oskar", "rafi", "june", "sam", "priya"), React("🥞", "june")], edited: 2),
        // Day 0
        Msg("pip", at(0, 8, 0), label: "birthday", reactions: [React("🎂", "wren", "hana", "tomas", "june", "sam", "oskar"), React(":froggo:", "hana", "wren")],
          embeds: [DemoEmbed(
              .rich, title: "🎂 Happy birthday, Nico!",
              description: "The Porch wishes <@nico> a year full of frogs, naps and wins at the bird game.",
              color: 0xf7a1c4, footer: "Pip · birthdays", footerIcon: "pip",
              thumbnail: DemoEmbedMedia(.sticker(seed: 0xf22, motif: .frog), width: 160, height: 160)
          )]),
        Msg("wren", at(0, 8, 1), "HAPPY BIRTHDAY NICO 🐸🎂", stickers: ["Froggo Dance"]),
        Msg("tomas", at(0, 8, 10), "happy birthday!! pancakes are now birthday pancakes"),
        Msg("nico", at(0, 9, 30), "thank you everyone 🥹🐸"),
        Msg("pip", at(0, 10, 0), "<@&gamers> next one's on the calendar!",
          embeds: [gameNight(on: 4, rsvps: "✅ Nico (birthday rules: he picks)", games: "whatever the birthday frog wants")],
          components: gameNightButtons),
        Msg("hana", at(0, 15, 0), "ok it's not a secret anymore", label: "cake",
          reactions: [React("🐸", "wren", "tomas", "june", "sam", "oskar", "rafi", "priya", burst: ["wren"]), React(":froggo:", "nico")],
          attachments: [.photo("frog-cake.jpg", seed: 0xca6f, .cake, alt: "A green frog-shaped birthday cake with five lit candles")]),
        Msg("nico", at(0, 15, 2), "I'M GOING TO CRY. it's perfect. it has little cheeks", replyTo: "cake"),
        Msg("priya", at(0, 17, 0), "back among the living. what did i miss", label: "catchup"),
        Msg("june", at(0, 17, 1), "a couch fit through a door, miso committed a felony, gerald unfurled and nico levelled up"),
        Msg("priya", at(0, 17, 2), "so a normal week", reactions: [React("😂", "june", "hana")]),
    ])
}
