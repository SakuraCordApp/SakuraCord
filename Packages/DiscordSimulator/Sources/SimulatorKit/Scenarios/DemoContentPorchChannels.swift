import Foundation

// The Porch's smaller channels and its forum.
extension DemoContent {
    // MARK: #kitchen

    static let porchKitchen = DemoChannel("kitchen", "kitchen", topic: "photos or it didn't happen 🍳", messages: [
        Msg("hana", at(-13, 19, 0), "what's everyone cooking tonight. i need ideas that aren't toast"),
        Msg("tomas", at(-13, 19, 2), "crispy chili oil eggs. this recipe changed my life https://www.smallkitchenbigflavour.com/recipes/crispy-chili-oil",
          label: "chili",
          embeds: [DemoEmbed(
              .article, url: "https://www.smallkitchenbigflavour.com/recipes/crispy-chili-oil",
              title: "Crispy Chili Oil (The Only One You'll Need)",
              description: "Shallots, garlic and plenty of chili flakes, fried slowly until everything crunches. Spoon it over eggs, noodles, rice… or straight from the jar.",
              color: 0xc2452d, provider: "Small Kitchen, Big Flavour",
              thumbnail: DemoEmbedMedia(.photo(seed: 0xc41, scene: .food), width: 400, height: 300)
          )]),
        Msg("hana", at(-13, 19, 5), "the crunchy bits!!! 🤤", replyTo: "chili"),
        Msg("june", at(-13, 19, 10), "i'm having pasta. i'm always having pasta. carb loading is a personality"),
        Msg("rafi", at(-12, 18, 30), "made a curry so spicy i had to open a window. 10/10 would suffer again"),
        Msg("hana", at(-11, 8, 10), "milk bread day 🍞", reactions: [React("🤤", "tomas", "priya", "wren")],
          attachments: [.photo("milk-bread.jpg", seed: 0xb2ead, .food, alt: "A golden loaf of milk bread on a wooden board")]),
        Msg("hana", at(-11, 8, 11), "[my grandma's milk bread](https://notes.theporch.club/milk-bread) for whoever asked last week. she'd want it shared 💛"),
        Msg("priya", at(-11, 8, 30), "it was me. i will make it after exams. *after* exams", label: "after"),
        Msg("hana", at(-11, 8, 31), "> after exams\nfamous last words", replyTo: "after"),
        Msg("tomas", at(-10, 12, 0), """
        foolproof weeknight dal, by request:
        1. rinse 1 cup red lentils
        2. simmer with 3 cups water, turmeric and salt for 20 min
        3. separate pan: oil, cumin seeds, garlic, chili, until it *smells like heaven*
        4. pour the hot oil over the lentils. it will sizzle. that's the point
        5. lemon. always lemon
        """, label: "dal", reactions: [React("📝", "sam", "nico", "june")], pinned: true),
        Msg("tomas", at(-10, 12, 1), system: .pinned("dal")),
        Msg("rafi", at(-10, 12, 5), "step 4 is chemistry and i respect it"),
        Msg("sam", at(-9, 19, 0), "tried the dal. my flatmate asked if i'd \"bought it from somewhere\" 😌", replyTo: "dal"),
        Msg("tomas", at(-9, 19, 2), "highest compliment"),
        Msg("hana", at(-8, 14, 0), """
        sourdough ratios for <@june> since you asked
        ```
        flour     500g
        water     350g
        starter   100g
        salt       10g
        ```
        mix, wait, fold, wait, fold, wait, panic, bake
        """),
        Msg("june", at(-8, 14, 5), "i assume the panic step is crucial"),
        Msg("hana", at(-8, 14, 5), "the most important step"),
        Msg("oskar", at(-7, 20, 0), "is it normal for rice to be crunchy"),
        Msg("tomas", at(-7, 20, 0), "no"),
        Msg("oskar", at(-7, 20, 1), "cool cool cool", reactions: [React("😂", "tomas", "hana")]),
        Msg("nico", at(-6, 18, 0), "made dumplings for the first time. they look like little hats",
          attachments: [.photo("dumpling-hats.jpg", seed: 0xd0e, .food, alt: "A plate of slightly lopsided homemade dumplings")]),
        Msg("tomas", at(-6, 18, 2), "little hats are the correct shape actually", reactions: [React("🥟", "nico", "hana")]),
        Msg("lou", at(-5, 9, 30), "in lisbon and i've had four pastéis de nata today. it's 9:30am"),
        Msg("hana", at(-5, 9, 31), "FOUR"),
        Msg("lou", at(-5, 9, 31), "it's research"),
        Msg("hana", at(-3, 16, 0), "miso would like to state she has no further comment on the croissant", stickers: ["Miso Loaf"]),
        Msg("tomas", at(0, 11, 0), "first meal in the new kitchen: pancakes for one. practice run for saturday 🥞", label: "pancakes",
          reactions: [React("🥞", "june", "hana", "wren"), React(":porchlove:", "wren")],
          attachments: [.photo("pancakes.jpg", seed: 0x9a2c, .food, alt: "A stack of pancakes with berries on a white plate")]),
        Msg("hana", at(0, 11, 5), "いただきます 🙏"),
        Msg("june", at(0, 11, 10), "i was promised pancakes and i see them. on saturday they will be mine", replyTo: "pancakes"),
    ])

    // MARK: #pets-and-plants

    static let porchPets = DemoChannel("pets", "pets-and-plants", topic: "creatures, leafy or furry", messages: [
        Msg("felix", at(-10, 10, 20), "as promised. this is biscuit", label: "biscuit",
          reactions: [React("🐕", "hana", "june", "wren", "nico", "sam"), React(":porchlove:", "wren")],
          attachments: [.photo("biscuit.jpg", seed: 0xb15c, .dog, alt: "A golden dog with floppy ears lying on a blue rug")]),
        Msg("hana", at(-10, 10, 22), "BISCUIT 😭 those ears", replyTo: "biscuit"),
        Msg("wren", at(-10, 10, 25), "biscuit is now the porch's dog. no take-backs"),
        Msg("felix", at(-10, 10, 26), "she's thrilled"),
        Msg("wren", at(-9, 15, 0), """
        people keep asking about gerald so here's the routine:
        - bright, indirect light
        - water when the top 2–3cm of soil is dry
        - wipe the leaves once a month
        - tell him he's doing great (optional, but he notices)
        """, label: "routine"),
        Msg("nico", at(-9, 15, 10), "do i tell my cactus he's doing great"),
        Msg("wren", at(-9, 15, 11), "your cactus KNOWS he's doing great"),
        Msg("sam", at(-8, 11, 0), "propagation station is getting out of hand",
          attachments: [.photo("jars.jpg", seed: 0x9a25, .plant, alt: "Plant cuttings rooting in glass jars on a sunny windowsill")]),
        Msg("hana", at(-8, 11, 5), "out of hand is the goal"),
        Msg("felix", at(-7, 8, 0), "post-race zoomies. she ran to the 15k mark and back and STILL had this in her",
          attachments: [.video("biscuit-zoomies.mp4", alt: "Biscuit the dog sprinting in circles in a park")]),
        Msg("june", at(-7, 8, 30), "she's a better athlete than all of us"),
        Msg("hana", at(-6, 20, 0), "loaf mode activated", attachments: [.gif("miso-loaf.gif", seed: 0x3154, motif: .cat, alt: "Miso the cat as a bouncing loaf")]),
        Msg("nico", at(-5, 17, 0), "saw a frog at the pond today. not my frog. just a frog. still made my day 🐸"),
        Msg("wren", at(-5, 17, 2), "every frog is your frog spiritually", reactions: [React(":froggo:", "nico")]),
        Msg("rafi", at(-4, 12, 0), "my basil has died again. what am i doing wrong", label: "basil"),
        Msg("wren", at(-4, 12, 5), "watering it every day?", replyTo: "basil"),
        Msg("rafi", at(-4, 12, 6), "...yes"),
        Msg("wren", at(-4, 12, 6), "there it is. let it dry out a bit between drinks 🌿"),
        Msg("felix", at(-2, 9, 0), "biscuit met a cat today. the cat won"),
        Msg("hana", at(-2, 9, 5), "was it miso. it's always miso"),
        Msg("felix", at(-2, 9, 6), "different cat. but miso's reputation precedes her", reactions: [React(":miso:", "hana")]),
        Msg("wren", at(0, 12, 0), "seedling haul from the garden 🍅🌿 tomás, your balcony tomatoes are on my windowsill", label: "seedlings",
          attachments: [.photo("seedlings.jpg", seed: 0x5eed, .garden, alt: "Rows of young tomato and basil seedlings")]),
        Msg("tomas", at(0, 12, 5), "my CHILDREN", replyTo: "seedlings"),
    ])

    // MARK: #recs

    static let porchRecs = DemoChannel("recs", "recommendations", topic: "books, shows, music, podcasts. spoilers in spoiler tags please", messages: [
        Msg("sam", at(-12, 21, 0), "book rec: *The Lighthouse at Mollow Point*. slow, cozy, then absolutely wrecks you in the last 30 pages"),
        Msg("priya", at(-12, 21, 5), "how badly wrecked"),
        Msg("sam", at(-12, 21, 6), "||the lighthouse keeper was the narrator's grandmother the whole time|| levels of wrecked"),
        Msg("nico", at(-12, 21, 7), "SAM"),
        Msg("sam", at(-12, 21, 7), "i hid it!!", edited: 1),
        Msg("june", at(-11, 20, 0), "podcast for long runs: Small Hours. two retired detectives solving very low-stakes mysteries https://smallhours.fm",
          embeds: [DemoEmbed(
              .link, url: "https://smallhours.fm", title: "Small Hours",
              description: "Two retired detectives. One small town. Mysteries of absolutely no consequence. New episodes every Thursday.",
              color: 0x3d4a8a, provider: "smallhours.fm",
              thumbnail: DemoEmbedMedia(.photo(seed: 0x5a11, scene: .city), width: 300, height: 300)
          )]),
        Msg("oskar", at(-11, 20, 10), "the missing garden gnome episode is peak"),
        Msg("rafi", at(-10, 20, 30), "this documentary about glassmaking is unreasonably soothing https://www.youtube.com/watch?v=k4Vb9xQm2Tz",
          embeds: [DemoEmbed(
              .video, url: "https://www.youtube.com/watch?v=k4Vb9xQm2Tz", title: "How Glass Is Made · one quiet hour in a glassworks",
              description: "No narration, no music. Just furnaces, patience and molten glass.",
              color: 0xff0000, provider: "YouTube", authorName: "Maker's Hour",
              thumbnail: DemoEmbedMedia(.photo(seed: 0x61a5, scene: .sunset), width: 1_280, height: 720),
              video: DemoEmbedMedia(.bundled("benchmark-video.mp4"), width: 1_280, height: 720)
          )]),
        Msg("hana", at(-10, 20, 35), "rafi this is the most rafi recommendation possible"),
        Msg("sam", at(-9, 22, 0), "book club: the lighthouse one", system: .threadCreated,
          thread: DemoThread("book club: the lighthouse one", [
              Msg("sam", at(-9, 22, 1), "for those who've finished. spoilers fully allowed in here"),
              Msg("priya", at(-8, 23, 30), "finished it on the bus and had to stare out of the window for ten minutes"),
              Msg("nico", at(-8, 23, 40), "the grandmother reveal. the LETTERS. i'm fine"),
              Msg("wren", at(-7, 10, 0), "the bit where she relights the lamp after the storm 😭"),
              Msg("sam", at(-7, 10, 4), "next pick: something with zero lighthouses. for our health"),
          ])),
        Msg("lou", at(-8, 23, 0), "music for a sunny day: anything by The Paper Lanterns. thank me later"),
        Msg("wren", at(-8, 23, 5), "LOU. i've had them on repeat all month"),
        Msg("nico", at(-6, 21, 0), "game rec: Pond Life. you are a frog. you manage a pond. that's it. i've played 40 hours"),
        Msg("tomas", at(-6, 21, 2), "of course you have", reactions: [React(":froggo:", "nico", "hana")]),
        Msg("priya", at(0, 18, 0), "now that i have free time again: give me your best comfort shows. making a list", label: "list"),
        Msg("hana", at(0, 18, 5), "anything with a baking competition", replyTo: "list"),
        Msg("sam", at(0, 18, 6), "*Quiet Harbour*. it's about a ferry captain and nothing bad ever happens"),
        Msg("june", at(0, 18, 10), "> nothing bad ever happens\nsold"),
    ])

    // MARK: #travel

    static let porchTravel = DemoChannel("travel", "travel", topic: "postcards from wherever you are 🗺️", messages: [
        Msg("tomas", at(-9, 10, 0), "lou, read this before you go https://www.slowtravelnotes.com/lisbon-by-neighbourhood",
          embeds: [DemoEmbed(
              .article, url: "https://www.slowtravelnotes.com/lisbon-by-neighbourhood", title: "Lisbon by neighbourhood: a slow guide",
              description: "Seven hills, one tram line everyone tells you about, and the quiet corners they don't.",
              color: 0x2e86ab, provider: "Slow Travel Notes", authorName: "Inês & Tom",
              image: DemoEmbedMedia(.photo(seed: 0x1150, scene: .city), width: 1_200, height: 630)
          )]),
        Msg("lou", at(-8, 13, 0), "made it 🇵🇹 the light here is unreal", label: "arrived",
          reactions: [React("😍", "hana", "wren", "june", "tomas"), React("🇵🇹", "tomas")],
          attachments: [
              .photo("alfama.jpg", seed: 0x1151, .city, alt: "Rooftops of an old hillside neighbourhood at dusk"),
              .photo("river-sunset.jpg", seed: 0x1152, .sunset, alt: "Sunset over a wide river"),
              .photo("nata.jpg", seed: 0x1153, .food, alt: "Custard tarts on a small plate"),
              .photo("sintra-hills.jpg", seed: 0x1154, .landscape, alt: "Green hills under a blue sky"),
          ]),
        Msg("hana", at(-8, 13, 5), "the NATA", replyTo: "arrived"),
        Msg("wren", at(-8, 13, 6), "the light!!! i want to paint every wall i see"),
        Msg("lou", at(-8, 13, 10), "making a thread so i stop flooding the channel",
          thread: DemoThread("lisbon plans 🗺️", [
              Msg("lou", at(-8, 13, 11), """
              ### the plan
              - **tue**: tram, castle, get lost in alfama
              - **wed**: sintra day trip
              - **thu**: belém + more nata
              - **fri**: nothing. sit by the river. eat.
              """),
              Msg("tomas", at(-8, 13, 20), "go to a tasca for lunch. the tiny ones with a handwritten menu"),
              Msg("lou", at(-8, 13, 22), "noted!!"),
              Msg("june", at(-8, 14, 0), "if you see a run club by the river, report back"),
              Msg("lou", at(-6, 8, 30), "saw one. they were very fast. i waved", reactions: [React("😂", "june")]),
          ])),
        Msg("lou", at(-6, 17, 0), "this viewpoint at golden hour 😮‍💨 https://pics.louwanders.net/miradouro.jpg",
          embeds: [DemoEmbed(.image, url: "https://pics.louwanders.net/miradouro.jpg",
                             thumbnail: DemoEmbedMedia(.photo(seed: 0x1155, scene: .sunset), width: 1_600, height: 1_200))]),
        Msg("rafi", at(-6, 17, 5), "the colours!"),
        Msg("lou", at(-5, 21, 0), "learned \"obrigada\" and now i say it 400 times a day"),
        Msg("oskar", at(-5, 21, 2), "that's how you get good at a language"),
        Msg("lou", at(-3, 19, 0), "last night 🥲 one more sunset",
          attachments: [.photo("last-sunset.jpg", seed: 0x1156, .sunset, alt: "A golden sunset over the water")]),
        Msg("lou", at(-2, 14, 0), "home. jet lag-ish. nata delivered to hana as promised 📦", label: "home"),
        Msg("hana", at(-2, 14, 20), "can confirm. they survived the flight. they did not survive me", replyTo: "home"),
        Msg("nico", at(-2, 14, 30), "where's MY nata"),
        Msg("lou", at(-2, 14, 31), "you're getting something better. sunday 🤫"),
    ])

    // MARK: #running

    static let porchRunning = DemoChannel("running", "running", topic: "slow miles welcome 🐢", messages: [
        Msg("june", at(-13, 6, 30), "training week 12 of 12. taper time, aka the hardest part, which is not running"),
        Msg("wren", at(-13, 7, 30), "what does taper mean"),
        Msg("june", at(-13, 7, 31), "running less so your legs are fresh on race day. my brain hates it"),
        Msg("june", at(-12, 18, 0), """
        race plan, for accountability:
        ```
        km  1-5    6:00/km   (hold back!!)
        km  6-15   5:35/km
        km 16-21   whatever's left
        ```
        """, label: "plan", pinned: true),
        Msg("june", at(-12, 18, 1), system: .pinned("plan")),
        Msg("sam", at(-12, 18, 5), "\"whatever's left\" is my approach to everything"),
        Msg("june", at(-11, 6, 0), "<@&runners> sunrise loop in the morning, anyone?"),
        Msg("wren", at(-11, 6, 5), "i'll come for the first 3k and then get a coffee"),
        Msg("june", at(-11, 6, 5), "valid"),
        Msg("felix", at(-10, 11, 0), "hi runners 👋 biscuit and i do the canal loop most mornings, always happy to have company"),
        Msg("pip", at(-9, 21, 0), "⏰ Okay <@june>, I'll remind you to **stretch** <t:-8@8:00:R>.", interaction: DemoInteraction("june", "remind")),
        Msg("pip", at(-8, 8, 0), "⏰ <@june>, you asked me to remind you: **stretch**"),
        Msg("june", at(-8, 20, 0), "kit laid out. bib pinned. going to bed at 9 like a child"),
        Msg("felix", at(-7, 8, 10), "the sign 🪧 https://pics.biscuitandfelix.net/the-sign.jpg",
          embeds: [DemoEmbed(.image, url: "https://pics.biscuitandfelix.net/the-sign.jpg",
                             thumbnail: DemoEmbedMedia(.photo(seed: 0xb15d, scene: .dog), width: 1_200, height: 900))]),
        Msg("june", at(-7, 15, 0), "splits for the nerds: 5:58 / 5:41 / 5:33 / 5:29 (!!) / 5:52. the last 5k was spite and gummy bears", label: "splits"),
        Msg("rafi", at(-7, 15, 5), "negative split in the middle, textbook", replyTo: "splits"),
        Msg("june", at(-3, 8, 0), "recovery jog crew 🐢",
          attachments: [.photo("slow-crew.jpg", seed: 0x51c4, .landscape, alt: "A riverside path on a misty morning")]),
        Msg("felix", at(-3, 8, 5), "biscuit led the whole way"),
        Msg("june", at(0, 7, 0), "first run since the race. everything hurts. would recommend"),
        Msg("felix", at(0, 7, 30), "<@&runners> canal loop next sunday? 8am. coffee after"),
        Msg("wren", at(0, 7, 45), "in for the coffee", reactions: [React("☕", "felix", "june")]),
    ])

    // MARK: #band-room

    static let porchBand = DemoChannel("band-room", "band-room", topic: "Quiet Neighbours: practice tuesdays, loud always 🎸", messages: [
        Msg("oskar", at(-13, 21, 0), "<@&band> café gig confirmed!! friday after next, 8pm at the Corner Café. 45 minute set", label: "gig",
          reactions: [React("🎸", "sam", "wren"), React("🥁", "sam")]),
        Msg("sam", at(-13, 21, 2), "45 minutes. we have 38 minutes of songs"),
        Msg("oskar", at(-13, 21, 3), "we play slower"),
        Msg("wren", at(-12, 10, 0), "want a poster? i can do a sandwich board for out front too"),
        Msg("oskar", at(-12, 10, 2), "WREN. yes. please. we'll pay you in free entry"),
        Msg("wren", at(-12, 10, 3), "entry is already free"),
        Msg("oskar", at(-12, 10, 3), "and eternal gratitude", reactions: [React(":porchlove:", "wren")]),
        Msg("oskar", at(-11, 23, 40), "bassline idea, don't judge, it's late", label: "bassline", attachments: [.voiceMessage]),
        Msg("sam", at(-11, 23, 45), "that's actually great. hum it at practice", replyTo: "bassline"),
        Msg("sam", at(-9, 20, 0), "<@oskar> this is the groove i meant https://www.youtube.com/watch?v=Qm8sLwK2p0e",
          embeds: [DemoEmbed(
              .video, url: "https://www.youtube.com/watch?v=Qm8sLwK2p0e", title: "Laid-back groove in 10 minutes | bass lesson",
              color: 0xff0000, provider: "YouTube", authorName: "Low End Lessons",
              thumbnail: DemoEmbedMedia(.photo(seed: 0xba55, scene: .desk), width: 1_280, height: 720),
              video: DemoEmbedMedia(.bundled("benchmark-video.mp4"), width: 1_280, height: 720)
          )]),
        Msg("oskar", at(-9, 20, 10), "oh that's so good. stealing it"),
        Msg("wren", at(-7, 16, 0), "poster draft 🎨 thoughts?",
          attachments: [.photo("poster-draft.jpg", seed: 0x9057, .sunset, width: 960, height: 1_280, alt: "Gig poster draft: a sunset over rooftops with hand-lettered band name")]),
        Msg("sam", at(-7, 16, 5), "it's perfect. we don't deserve it"),
        Msg("oskar", at(-7, 16, 6), "frame it. we'll be famous one day and it'll be worth millions"),
        Msg("sam", at(-5, 22, 30), "tonight's practice. the outro finally works", reactions: [React("🔥", "oskar", "wren", "hana")],
          attachments: [.video("practice-clip.mp4", alt: "A short clip from band practice")]),
        Msg("oskar", at(-5, 22, 35), "we sound like a real band!!!"),
        Msg("sam", at(-5, 22, 35), "we ARE a real band"),
        Msg("oskar", at(-4, 13, 0), "final setlist 📝", label: "setlist",
          attachments: [.file("setlist.txt", bundled: "demo-notes.txt", contentType: "text/plain; charset=utf-8", size: 371)], pinned: true),
        Msg("oskar", at(-4, 13, 1), system: .pinned("setlist")),
        Msg("sam", at(-4, 13, 5), "don't forget ||the surprise cover at the end||", replyTo: "setlist"),
        Msg("oskar", at(-2, 23, 58), "rough mix from tonight, someone recorded it from the bar",
          attachments: [.audio("corner-cafe-rough-mix.ogg")]),
        Msg("sam", at(-2, 23, 59), "my snare sounds like a tin of beans and i love it"),
        Msg("hana", at(-1, 0, 30), "the surprise cover had the whole café singing 🥹"),
        Msg("oskar", at(0, 12, 0), "the café asked us back next month 👀", reactions: [React("🎉", "sam", "wren", "hana", burst: ["wren"])]),
        Msg("sam", at(0, 12, 5), "WE'RE BACK"),
    ])

    // MARK: #study-hall

    static let porchStudy = DemoChannel("study-hall", "study-hall", topic: "heads down. cameras optional. snacks encouraged", slowmodeSeconds: 30, messages: [
        Msg("priya", at(-13, 20, 0), "### tonight\n- cardiology deck\n- renal deck\n- eat a vegetable"),
        Msg("rafi", at(-13, 20, 5), "add \"go outside for 10 min\". non-negotiable"),
        Msg("priya", at(-13, 20, 6), "fine. *fine*."),
        Msg("sam", at(-12, 14, 0), "library's open til 10 this week if anyone needs a quiet desk. i'll pretend not to know you"),
        Msg("priya", at(-12, 14, 2), "i'll be at the desk by the window. do not perceive me"),
        Msg("priya", at(-11, 22, 0), "the cave", label: "cave",
          attachments: [.photo("the-cave.jpg", seed: 0xcade, .desk, alt: "A desk covered in flashcards and a mug of coffee")]),
        Msg("june", at(-11, 22, 5), "this looks like a crime board", replyTo: "cave"),
        Msg("priya", at(-11, 22, 5), "it IS a crime board. the crime is renal physiology"),
        Msg("rafi", at(-10, 16, 0), "grading 90 lab reports. someone wrote that water boils at \"hot\". technically not wrong",
          reactions: [React("😂", "priya", "sam", "wren")]),
        Msg("rafi", at(-10, 16, 1), "spreadsheet tip for the teachers among us (me): `=AVERAGE(B2:B91)` and then lie down"),
        Msg("pip", at(-8, 19, 0), "🍅 Focus timer started for <@priya>: **25 minutes**. I'll ping you <t:-8@19:25:R>.",
          components: [DemoActionRow([
              .button(label: "Pause", style: .secondary, emoji: "⏸️", customID: "focus:pause"),
              .button(label: "Stop", style: .danger, customID: "focus:stop"),
              .button(label: "Add 5 min", style: .primary, customID: "focus:extend", disabled: true),
          ])], interaction: DemoInteraction("priya", "focus")),
        Msg("priya", at(-6, 21, 0), "> you don't have to be brilliant, you just have to be consistent\nwho said this. i need to thank them", label: "quote"),
        Msg("rafi", at(-6, 21, 2), "me, last tuesday", replyTo: "quote"),
        Msg("priya", at(-6, 21, 2), "oh. thank you rafi 🥲"),
        Msg("priya", at(-4, 6, 30), "leaving for the exam. this channel kept me going 💛", reactions: [React("💛", "sam", "rafi", "wren")]),
        Msg("sam", at(-4, 6, 45), "go get it"),
        Msg("priya", at(-1, 9, 20), "passed!! the cave is officially a regular desk again", reactions: [React("🎉", "rafi", "sam", "june"), React(":porchlove:", "wren")]),
    ])

    // MARK: #ask-the-porch

    static let porchForum = DemoChannel(
        "ask-the-porch", "ask-the-porch", kind: .forum, topic: "need a drill, a ladder or a second opinion? ask here",
        forumTags: [
            DemoForumTag("borrow", emoji: "🧰"), DemoForumTag("advice", emoji: "💡"),
            DemoForumTag("recs", emoji: "⭐"), DemoForumTag("solved", emoji: "✅", moderated: true),
        ],
        posts: [
            DemoForumPost("how this works 📌", tags: [], pinned: true, [
                Msg("wren", at(-13, 10, 5), "one post per question, tag it. when it's sorted a Porch Light will add ✅ solved so we can find answers later 💛"),
            ]),
            DemoForumPost("anyone have a drill?", tags: ["borrow", "solved"], [
                Msg("tomas", at(-9, 18, 0), "need to put up shelves in the new place. mine is in a box labelled \"misc 3\" and i don't know where misc 3 is"),
                Msg("rafi", at(-9, 18, 5), "i have two. one's a hammer drill if you're dealing with brick"),
                Msg("tomas", at(-9, 18, 6), "it IS brick. how did you know"),
                Msg("rafi", at(-9, 18, 6), "everyone's walls are brick when they're putting up shelves"),
                Msg("tomas", at(-8, 12, 0), "picked it up, thank you 🙏", reactions: [React("🔧", "rafi")]),
            ]),
            DemoForumPost("candle wax on a linen tablecloth, help", tags: ["advice", "solved"], [
                Msg("hana", at(-8, 20, 0), "game night casualty. how do i get it out"),
                Msg("june", at(-8, 20, 10), "freeze it, scrape off what you can, then iron it through paper towels"),
                Msg("sam", at(-8, 20, 12), "brown paper bag works better than paper towel"),
                Msg("hana", at(-7, 10, 0), "it worked!! tablecloth saved", reactions: [React("🙌", "june", "sam")]),
            ]),
            DemoForumPost("what do i bring to a move besides my arms", tags: ["advice"], [
                Msg("nico", at(-5, 20, 0), "first time helping someone move. what's the etiquette"),
                Msg("rafi", at(-5, 20, 4), "gloves, a box cutter, snacks"),
                Msg("tomas", at(-5, 20, 6), "and a good attitude about couches"),
                Msg("june", at(-5, 20, 9), "water. lots of water"),
                Msg("nico", at(-5, 20, 11), "noted: gloves, snacks, water, couch attitude"),
            ]),
            DemoForumPost("lost: one blue glove", tags: ["solved"], archived: true, [
                Msg("sam", at(-3, 9, 0), "left a blue glove at wren's after game night. hole in the thumb. sentimental value"),
                Msg("wren", at(-3, 9, 20), "found it! it was in the bird game box"),
                Msg("sam", at(-3, 9, 21), "of course it was"),
            ]),
            DemoForumPost("sewing machine for a total beginner?", tags: ["recs", "borrow"], [
                Msg("june", at(-2, 11, 0), "want to hem my own running shorts. is that a reasonable first project"),
                Msg("hana", at(-2, 11, 10), "very reasonable. you just need a good straight stitch, ignore the ones with 200 stitches"),
                Msg("lou", at(-2, 15, 0), "my aunt's old machine is in my cupboard, want to borrow it?"),
                Msg("june", at(-2, 15, 2), "LOU YES", reactions: [React("🧵", "lou", "hana")]),
            ]),
        ]
    )
}
