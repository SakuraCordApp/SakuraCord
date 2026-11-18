import Foundation

/// The demo world: a small server of friends ("The Porch"), a boosted
/// community-garden server, DMs and a group DM, seen by the signed-in `wren`.
///
/// Lines are written for an evening (`now` is 21:30 on day 0), and day 0 is
/// whichever weekday the world starts on, so the chat names weekdays with
/// `<day:…>` placeholders.
public enum DemoContent {
    public static let selfKey = "wren"
    public static let now = DemoTime(day: 0, 21, 30)

    public static var guilds: [DemoGuild] { [porch, garden] }

    public static let people: [DemoPerson] = [
        DemoPerson(
            key: "wren", username: "wren.alder", displayName: "Wren", pronouns: "they/them",
            bio: "sign painter by day, plant hoarder by night 🌿\nnegotiating with a monstera named Gerald",
            premium: .nitro,
            presence: DemoPresence(.online, custom: "repotting everything", emoji: "🪴",
                                   activity: .listening(song: "Slow Tide", artist: "The Paper Lanterns", album: "Harbour Songs")),
            avatar: DemoImageStyle(seed: 0x57e1, palette: 7, animated: true, art: .drawing(.leaf, background: 0xe1bee7)), banner: DemoImageStyle(seed: 0x57e2, palette: 7),
            bannerColor: 0x52b788, accentColor: 0x2d6a4f, themeColors: [0x2d6a4f, 0xd8f3dc]
        ),
        DemoPerson(
            key: "tomas", username: "tomas.b", displayName: "Tomás", pronouns: "he/him",
            bio: "line cook. will feed you.\nnew kitchen, who dis 🍳", premium: .nitroBasic,
            presence: DemoPresence(.idle, custom: "unpacking forever", emoji: "📦"),
            avatar: DemoImageStyle(seed: 0x7012, palette: 4, art: .drawing(.box, background: 0x8d6e63)), bannerColor: 0xffb347, accentColor: 0xd1495b
        ),
        DemoPerson(
            key: "priya", username: "priya.k", displayName: "Priya", pronouns: "she/her",
            bio: "med student. powered by iced coffee and flashcards ☕", premium: .none,
            presence: DemoPresence(.idle, custom: "passed. sleeping for a week", emoji: "😴"),
            avatar: DemoImageStyle(seed: 0x9a1a, palette: 3, art: .drawing(.moon, background: 0x283593)), bannerColor: 0x8e7cc3, accentColor: 0x4b3f72
        ),
        DemoPerson(
            key: "june", username: "junebug.runs", displayName: "June", pronouns: "she/her",
            bio: "slow runner, fast snacker 🏃‍♀️\n21.1 km survivor", premium: .none,
            presence: DemoPresence(.online, custom: "sub-2 club", emoji: "🏅"),
            avatar: DemoImageStyle(seed: 0x1e7e, palette: 8, art: .drawing(.shoe, background: 0xffe1d6)), bannerColor: 0xff9e80, accentColor: 0xf25f5c
        ),
        DemoPerson(
            key: "oskar", username: "oskar.lund", displayName: "Oskar", pronouns: "he/him",
            bio: "bass in Quiet Neighbours 🎸\nbike: alive again", premium: .none,
            presence: DemoPresence(.online, activity: .listening(song: "Lowlands", artist: "Mossgrove", album: "Night Ferry")),
            avatar: DemoImageStyle(seed: 0x05ca, palette: 9, art: .drawing(.guitar, background: 0x00695c)), bannerColor: 0x3d4a8a, accentColor: 0x6c7bbf
        ),
        DemoPerson(
            key: "hana", username: "hana.bakes", displayName: "Hana", pronouns: "she/they",
            bio: "baker 🍞 cat mom to Miso (a thief)", premium: .none,
            presence: DemoPresence(.online, custom: "proofing", emoji: "🍞"),
            avatar: DemoImageStyle(seed: 0x4a7a, palette: 10, art: .drawing(.bread, background: 0xfde9cc)), bannerColor: 0xe2a0b5, accentColor: 0x9d6381
        ),
        DemoPerson(
            key: "rafi", username: "rafi.m", displayName: "Rafi", pronouns: "he/him",
            bio: "chemistry teacher. garage full of bike parts. it was a positive hm", premium: .none,
            presence: DemoPresence(.idle, activity: .playing("Lighthouse Keeper")),
            avatar: DemoImageStyle(seed: 0x2af1, palette: 1, art: .photo(.bike)), bannerColor: 0x2e86ab, accentColor: 0x1b4965
        ),
        DemoPerson(
            key: "lou", username: "lou.wanders", displayName: "Lou", pronouns: "she/her",
            bio: "will plan a whole trip around one bakery ✈️", premium: .none,
            presence: DemoPresence(.offline),
            avatar: DemoImageStyle(seed: 0x10a0, palette: 0, art: .photo(.sunset)), bannerColor: 0xf28c8c, accentColor: 0x6c5b9e
        ),
        DemoPerson(
            key: "sam", username: "sam.drums", displayName: "Sam", pronouns: "they/them",
            bio: "drums @ Quiet Neighbours\nshhh @ the library", premium: .none,
            presence: DemoPresence(.dnd, custom: "library shift", emoji: "📚"),
            avatar: DemoImageStyle(seed: 0x5a3d, palette: 11, art: .monogram("SD", background: 0x263238)), bannerColor: 0x6b8094, accentColor: 0x3a4a5c
        ),
        DemoPerson(
            key: "nico", username: "nico.ribbit", displayName: "Nico", pronouns: "he/him",
            bio: "frog enthusiast 🐸 ask me about frogs", premium: .none,
            presence: DemoPresence(.online, custom: "birthday mode", emoji: "🎂", activity: .playing("Pond Life")),
            avatar: DemoImageStyle(seed: 0x71c0, palette: 2, art: .drawing(.frog, background: 0xd7f2d0)), bannerColor: 0x5e9f6e, accentColor: 0x2f5d50
        ),
        DemoPerson(
            key: "felix", username: "felix.and.biscuit", displayName: "Felix", pronouns: "he/him",
            bio: "Biscuit's human 🐕", premium: .none,
            presence: DemoPresence(.offline),
            avatar: DemoImageStyle(seed: 0xfe11, palette: 6, art: .photo(.dog)), bannerColor: 0xe0b184, accentColor: 0x6b4f4f
        ),
        DemoPerson(
            key: "marisol", username: "marisol.grows", displayName: "Marisol", pronouns: "she/her",
            bio: "Linden Street Garden coordinator 🌻 compost evangelist", premium: .none,
            presence: DemoPresence(.online, custom: "turning the compost", emoji: "🌻"),
            avatar: DemoImageStyle(seed: 0x3a21, palette: 4, art: .photo(.plant)), bannerColor: 0xffe29a, accentColor: 0xff7f50
        ),
        DemoPerson(
            key: "kofi", username: "kofi.honey", displayName: "Kofi", pronouns: "he/him",
            bio: "keeps the bees. brings honey to meetings 🐝", premium: .none,
            presence: DemoPresence(.idle),
            avatar: DemoImageStyle(seed: 0xc0f1, palette: 6, art: .drawing(.bee, background: 0x4e342e)), bannerColor: 0xb07d62, accentColor: 0xffb347
        ),
        DemoPerson(
            key: "ada", username: "ada.p", displayName: "Ada", pronouns: "she/her",
            bio: "retired music teacher. plot 14. grows too many courgettes", premium: .none,
            presence: DemoPresence(.offline),
            avatar: nil, bannerColor: 0xfad2e1, accentColor: 0x9d6381
        ),
        DemoPerson(
            key: "rosa", username: "rosa.inks", displayName: "Rosa", pronouns: "she/her",
            bio: "illustrator. met you at the garden open day 🌱", premium: .none,
            presence: DemoPresence(.online),
            avatar: nil, bannerColor: 0xe07a9c, accentColor: 0xa23b72
        ),
        DemoPerson(
            key: "pip", username: "pip", displayName: "Pip", pronouns: "",
            bio: "Porch helper 🏡 game nights, reminders, birthdays and the watering rota.", premium: .none,
            presence: DemoPresence(.online, activity: .watching("the porch")),
            avatar: DemoImageStyle(seed: 0x0919, palette: 1, art: .drawing(.robot, background: 0xad1457)), bannerColor: 0x56c1c1, accentColor: 0x2e86ab, isBot: true
        ),
    ]

    public static let relationships: [DemoRelationship] = [
        DemoRelationship("tomas", since: DemoTime(day: -900, 18, 2)),
        DemoRelationship("priya", since: DemoTime(day: -870, 12, 40)),
        DemoRelationship("june", since: DemoTime(day: -640, 9, 5)),
        DemoRelationship("oskar", since: DemoTime(day: -800, 22, 11)),
        DemoRelationship("hana", since: DemoTime(day: -910, 15, 30)),
        DemoRelationship("rafi", nickname: "bike wizard 🔧", since: DemoTime(day: -500, 19, 0)),
        DemoRelationship("lou", since: DemoTime(day: -720, 8, 45)),
        DemoRelationship("sam", since: DemoTime(day: -560, 20, 15)),
        DemoRelationship("nico", since: DemoTime(day: -430, 21, 50)),
        DemoRelationship("felix", since: DemoTime(day: -10, 10, 30)),
        DemoRelationship("marisol", since: DemoTime(day: -200, 11, 0)),
        DemoRelationship("ada", since: DemoTime(day: -180, 16, 20)),
        DemoRelationship("rosa", .incomingRequest, since: DemoTime(day: -1, 20, 5)),
        DemoRelationship("kofi", .outgoingRequest, since: DemoTime(day: -3, 13, 0)),
    ]

    /// Standard (non-guild) stickers anyone can send.
    public static let standardStickers: [DemoSticker] = [
        DemoSticker("Wave", description: "Wave to say hi!", tags: "👋", format: .lottie, media: .bundled("benchmark-lottie.json")),
    ]

    public static let directChannels: [DemoDirectChannel] = [moveCrew, dmTomas, dmHana, dmPriya, dmMarisol]

    // MARK: Authoring shorthand

    typealias Msg = DemoMessage
    typealias React = DemoReaction

    static func at(_ day: Int, _ hour: Int, _ minute: Int) -> DemoTime { DemoTime(day: day, hour, minute) }

    // MARK: Direct messages

    static let dmTomas = DemoDirectChannel("dm-tomas", recipients: ["tomas"], messages: [
        Msg("tomas", at(-12, 20, 14), "ok be honest. is the couch coming with me out of love or stubbornness"),
        Msg("wren", at(-12, 20, 16), "both. that's what makes it a family heirloom"),
        Msg("tomas", at(-12, 20, 17), "it's from a flea market"),
        Msg("wren", at(-12, 20, 17), "a family heirloom *in progress*"),
        Msg("tomas", at(-9, 11, 2), "booked the van for <day:-1:l> 8:30 🚐 can you drive it? i panic on roundabouts"),
        Msg("wren", at(-9, 11, 5), "yes, if i get to pick the music", label: "van"),
        Msg("tomas", at(-9, 11, 5), "deal. no sea shanties", replyTo: "van"),
        Msg("wren", at(-9, 11, 6), "no promises"),
        Msg("tomas", at(-6, 21, 40), "", system: .call(participants: ["tomas", "wren"], durationMinutes: 14)),
        Msg("tomas", at(-6, 21, 56), "thanks for talking me down. i'm calm. i'm a calm person", edited: 1),
        Msg("wren", at(-6, 21, 57), "you're a calm person who owns a very large couch. both can be true"),
        Msg("tomas", at(-1, 22, 48), "last look at the old place. 6 years 🥲",
          attachments: [.photo("old-place.jpg", seed: 0x0d1a, .city, alt: "Rooftops at dusk seen from an empty apartment window")]),
        Msg("wren", at(-1, 22, 50), "it was a good kitchen. the new one's better though"),
        Msg("tomas", at(-1, 22, 51), "the new one has a gas stove and a couch that fits. i've peaked",
          reactions: [React("🛋️", "wren"), React(":couch:", "wren")]),
    ])

    static let dmHana = DemoDirectChannel("dm-hana", recipients: ["hana"], messages: [
        Msg("hana", at(-6, 13, 10), "ok so. nico's birthday is <day:0:l>. cake idea. you cannot tell him", label: "idea"),
        Msg("wren", at(-6, 13, 12), "my lips are sealed 🤐"),
        Msg("hana", at(-6, 13, 13), "||a frog. the whole cake is a frog. little cheeks and everything||", label: "secret"),
        Msg("wren", at(-6, 13, 13), "HANA", replyTo: "secret"),
        Msg("wren", at(-6, 13, 14), "he's going to cry", reactions: [React("🥹", "hana")]),
        Msg("hana", at(-4, 19, 32), "sketch v2, thoughts?",
          attachments: [.photo("frog-cake-sketch.jpg", seed: 0xca6e, .desk, width: 1_024, height: 768, alt: "Pencil sketches of a frog-shaped cake on notecards")]),
        Msg("wren", at(-4, 19, 40), "the cheeks!!! maybe pistachio sponge so it's green inside too?"),
        Msg("hana", at(-4, 19, 41), "oh you're a genius. pistachio it is", reactions: [React("💚", "wren")]),
        Msg("hana", at(-1, 23, 12), "cake is done. hiding it in the fridge behind the leeks. he will never look behind the leeks"),
        Msg("wren", at(0, 15, 20), "he cried. you made a grown man cry over a frog 🐸", label: "cried"),
        Msg("hana", at(0, 15, 22), "best review i've ever had", replyTo: "cried",
          reactions: [React("😂", "wren"), React("🐸", "wren", burst: ["wren"])]),
    ])

    static let dmPriya = DemoDirectChannel("dm-priya", recipients: ["priya"], unreadFrom: "lateone", messages: [
        Msg("wren", at(-6, 22, 30), "hey, no need to reply. just: you know this stuff. you've known it for months 💛"),
        Msg("priya", at(-6, 23, 5), "thank you. i needed that more than another flashcard"),
        Msg("priya", at(-4, 18, 55), "too tired to type", label: "voice", attachments: [.voiceMessage]),
        Msg("wren", at(-4, 19, 1), "\"i think i got the renal one right\" is the most hopeful thing i've ever heard", replyTo: "voice"),
        Msg("priya", at(-4, 19, 3), "😭 it was the hardest station"),
        Msg("wren", at(-1, 9, 8), "DOCTOR (eventually) PRIYA", reactions: [React("🥹", "priya")]),
        Msg("priya", at(-1, 9, 15), "i'm going to frame this message"),
        Msg("priya", at(0, 20, 41), "ok i've slept 14 hours. is it true about the frog cake", label: "lateone"),
        Msg("priya", at(0, 20, 41), "i need pictures. all of them"),
    ])

    static let dmMarisol = DemoDirectChannel("dm-marisol", recipients: ["marisol"], messages: [
        Msg("marisol", at(-11, 10, 0), "Hi Wren! Plot 7 is yours from next month 🌱 the previous gardener left some rhubarb, it's a keeper"),
        Msg("wren", at(-11, 10, 20), "oh amazing, thank you!! i've never grown rhubarb. or anything outside a pot, honestly"),
        Msg("marisol", at(-11, 10, 24), "Ha, everyone starts somewhere. Ada's plot is next to yours and she will adopt you"),
        Msg("marisol", at(-2, 9, 30), "Would you be up for painting a new sign for the shed? We'd pay you in honey and gratitude", label: "sign"),
        Msg("wren", at(-2, 9, 45), "honey is my preferred currency. yes!", replyTo: "sign", reactions: [React(":busybee:", "marisol")]),
    ])

    static let moveCrew = DemoDirectChannel(
        "gdm-move", recipients: ["tomas", "oskar", "rafi"], name: "move crew 📦",
        icon: DemoImageStyle(seed: 0x60e, palette: 4, art: .drawing(.box, background: 0xff8a65)), owner: "tomas", messages: [
            Msg("tomas", at(-8, 17, 0), "made a chat for <day:-1:l> logistics. you're here because you have arms"),
            Msg("tomas", at(-8, 17, 1), "", system: .recipientAdded("rafi")),
            Msg("rafi", at(-8, 17, 3), "and a chain tool"),
            Msg("tomas", at(-8, 17, 5), "", system: .channelNameChanged("move crew 📦")),
            Msg("tomas", at(-8, 17, 6), "", system: .channelIconChanged),
            Msg("oskar", at(-8, 17, 20), "what time and how many stairs"),
            Msg("tomas", at(-8, 17, 21), "9am. zero stairs. one couch", label: "plan"),
            Msg("oskar", at(-8, 17, 21), "the couch is worth ten stairs", replyTo: "plan"),
            Msg("wren", at(-4, 20, 10), "van's 85 for the day + fuel. splitting it four ways, rafi did the maths"),
            Msg("rafi", at(-4, 20, 12), """
            ```python
            van, fuel = 85.00, 23.40
            people = ["tomas", "wren", "oskar", "rafi"]
            share = round((van + fuel) / len(people), 2)
            print(share)  # 27.1
            ```
            """, label: "maths"),
            Msg("tomas", at(-4, 20, 13), "absolutely not, i'm paying for the van. you're paying in muscle", replyTo: "maths",
              reactions: [React("💪", "oskar", "rafi", "wren")]),
            Msg("tomas", at(-1, 7, 2), "", system: .call(participants: ["tomas", "oskar", "wren"], durationMinutes: 3)),
            Msg("oskar", at(-1, 7, 10), "on my way. by BIKE 🚲"),
            Msg("rafi", at(-1, 7, 11), "she lives"),
            Msg("tomas", at(-1, 20, 30), "thank you all. truly. the couch thanks you too", reactions: [React("❤️", "wren", "oskar", "rafi")]),
        ]
    )
}
