import Foundation

/// Seeded filler for large worlds: people, servers, channels, chat lines and
/// forum posts that read like ordinary friendly chatter. Index-based names
/// are unique for every index; everything else depends only on the RNG state.
public enum DemoText {
    // MARK: People

    /// A fictional person whose username is unique for every `index` and never
    /// collides with `DemoContent.people`.
    public static func person(index: Int) -> DemoPerson {
        let first = firstNames[index % firstNames.count]
        let prefix = surnamePrefixes[index % surnamePrefixes.count]
        let suffix = surnameSuffixes[index / surnamePrefixes.count % surnameSuffixes.count]
        // Coprime bank sizes make (first, surname) unique for every index below
        // their product; later rounds get a number.
        let round = index / (firstNames.count * surnamePrefixes.count * surnameSuffixes.count)
        let surname = prefix.prefix(1).uppercased() + prefix.dropFirst() + suffix
        var rng = SeededRandom(seed: 0xde30_7e47).fork("person-\(index)")
        let statuses: [DemoStatus] = [.online, .online, .idle, .dnd, .offline, .offline, .offline]
        let premium: DemoPremium = index % 11 == 0 ? .nitro : index % 7 == 0 ? .nitroBasic : .none
        let custom = rng.chance(0.3) ? rng.pick(customStatuses) : nil
        let presence = DemoPresence(rng.pick(statuses), custom: custom?.text, emoji: custom?.emoji)
        let avatar = DemoImageStyle(seed: rng.next(), palette: Int(rng.next() % 12))
        return DemoPerson(
            key: "person-\(index)",
            username: "\(first.lowercased()).\(surname.lowercased())\(round > 0 ? String(round) : "")",
            displayName: "\(first) \(surname)",
            pronouns: rng.pick(["she/her", "he/him", "they/them", "she/they", "he/they", ""]),
            bio: rng.chance(0.6) ? rng.pick(bios) : "",
            premium: premium,
            presence: presence,
            // About one in eleven server members never set an avatar, as in captured member lists.
            avatar: avatar.seed % 100 < 9 ? nil : avatar,
            banner: premium == .nitro ? DemoImageStyle(seed: rng.next(), palette: Int(rng.next() % 12)) : nil,
            bannerColor: UInt32(truncatingIfNeeded: rng.next()) & 0xffffff,
            accentColor: UInt32(truncatingIfNeeded: rng.next()) & 0xffffff
        )
    }

    // MARK: Places

    /// Unique for every index.
    public static func serverName(index: Int) -> String {
        let place = places[index % places.count]
        let group = groups[index % groups.count]
        let round = index / (places.count * groups.count)
        return round == 0 ? "\(place) \(group)" : "\(place) \(group) \(round + 1)"
    }

    /// Unique within a server for every index.
    public static func channelName(index: Int) -> String {
        let name = channelNames[index % channelNames.count]
        let round = index / channelNames.count
        return round == 0 ? name : "\(name)-\(round + 1)"
    }

    // MARK: Chat

    /// One believable chat line: short reactions, single sentences, the odd
    /// paragraph, sometimes with markdown, emoji or a link.
    public static func message(_ rng: inout SeededRandom) -> String {
        let roll = rng.unit()
        let text: String = switch roll {
        case ..<0.3: rng.pick(shortLines)
        case ..<0.72: sentence(&rng)
        case ..<0.92: "\(sentence(&rng)) \(sentence(&rng))"
        default: paragraph(&rng)
        }
        return decorate(text, &rng)
    }

    public static func forumPostTitle(_ rng: inout SeededRandom) -> String {
        switch rng.next() % 5 {
        case 0: "Best \(rng.pick(things)) for \(rng.pick(purposes))?"
        case 1: "Looking for \(rng.pick(neededThings))"
        case 2: "How do you \(rng.pick(tasks))?"
        case 3: "\(rng.pick(categories).capitalizedFirst) recommendations, please"
        default: "\(rng.pick(events).capitalizedFirst) this weekend, who's in?"
        }
    }

    public static func forumPostBody(_ rng: inout SeededRandom) -> String {
        var lines = [rng.pick(postOpeners), sentence(&rng)]
        if rng.chance(0.4) {
            lines.append((0 ..< Int(2 + rng.next() % 3)).map { _ in "- \(rng.pick(things))" }.joined(separator: "\n"))
        }
        lines.append(rng.pick(postClosers))
        return lines.joined(separator: "\n\n")
    }

    // MARK: Assembly

    private static func sentence(_ rng: inout SeededRandom) -> String {
        switch rng.next() % 7 {
        case 0: "just \(rng.pick(activities)) \(rng.pick(times)) and \(rng.pick(feelings))"
        case 1: "anyone \(rng.pick(questions))?"
        case 2: "\(rng.pick(subjects)) is \(rng.pick(judgements))"
        case 3: "\(rng.pick(plans)) \(rng.pick(times))"
        case 4: "can't believe \(rng.pick(surprises))"
        case 5: "\(rng.pick(reactionsOpeners)) \(rng.pick(subjects)) \(rng.pick(["though", "honestly", "tbh", "", "lol"]))"
            .trimmingCharacters(in: .whitespaces)
        default: "reminder: \(rng.pick(reminders))"
        }
    }

    private static func paragraph(_ rng: inout SeededRandom) -> String {
        switch rng.next() % 3 {
        case 0:
            "ok \(rng.pick(["plan", "list", "idea"])) for \(rng.pick(["saturday", "the trip", "next week", "the party"])):\n"
                + (0 ..< Int(2 + rng.next() % 3)).map { "\($0 + 1). \(rng.pick(plans))" }.joined(separator: "\n")
        case 1: "> \(sentence(&rng))\n\(rng.pick(shortLines))"
        default: "\(sentence(&rng)). \(sentence(&rng)). anyway \(rng.pick(shortLines))"
        }
    }

    private static func decorate(_ text: String, _ rng: inout SeededRandom) -> String {
        var text = text
        if rng.chance(0.08), let word = text.split(separator: " ").last, word.count > 3 {
            let wrap = rng.pick(["**", "*", "__", "~~", "||"])
            text = String(text.dropLast(word.count)) + wrap + String(word) + wrap
        }
        if rng.chance(0.05) { text += " " + rng.pick(links) }
        if rng.chance(0.03) { text += " `\(rng.pick(["brb", "afk", "eta 10", "/shrug"]))`" }
        if rng.chance(0.25) { text += " " + rng.pick(emoji) }
        return text
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Banks

// 61 first names, 16 prefixes and 17 suffixes: pairwise coprime sizes.
private let firstNames = [
    "Ada", "Alba", "Amir", "Anouk", "Arlo", "Bea", "Bodhi", "Cass", "Cleo", "Dara", "Eden", "Elio", "Esme", "Ezra",
    "Faye", "Finn", "Gus", "Hallie", "Idris", "Ines", "Iris", "Jonah", "Juno", "Kai", "Kit", "Lena", "Leo", "Luca",
    "Mabel", "Maren", "Milo", "Nell", "Noor", "Olive", "Omar", "Otto", "Pia", "Quinn", "Remy", "Rhea", "Rio", "Rumi",
    "Sana", "Saoirse", "Silas", "Suki", "Tamsin", "Teo", "Thea", "Uma", "Vera", "Wade", "Willa", "Yara", "Yusuf", "Zara",
    "Zeke", "Lior", "Mika", "Odile", "Pax",
]
private let surnamePrefixes = ["ash", "bram", "cole", "dun", "elder", "fen", "glen", "hart", "ivy", "kes", "lark", "moss", "north", "oak", "pell", "quill"]
private let surnameSuffixes = ["wick", "ford", "ley", "more", "by", "ton", "field", "worth", "brook", "dale", "hurst", "combe", "well", "ridge", "holt", "gate", "wood"]

private let bios = [
    "here for the snacks", "plant person 🌱", "probably outside", "amateur baker, professional eater", "dog walker (my own dog)",
    "slow runner", "always reading something", "learning the ukulele, sorry neighbours", "tea > coffee", "weekend hiker",
    "will talk about birds", "cooking my way through a cookbook", "night owl 🦉", "bike commuter", "collector of mugs",
]
private let customStatuses: [(text: String, emoji: String)] = [
    ("on a walk", "🚶"), ("baking", "🍞"), ("out for lunch", "🥪"), ("reading", "📖"), ("gardening", "🌱"),
    ("on holiday", "🏖️"), ("napping", "😴"), ("at the gym", "🏋️"), ("making soup", "🍲"), ("back later", "👋"),
]

// 13 places and 14 groups: coprime.
private let places = [
    "Maple Street", "Riverside", "Hilltop", "Old Town", "Harbour", "Northside", "Willow Lane", "Eastgate", "Cedar Park",
    "Lakeside", "Southbank", "Mill Road", "Orchard Row",
]
private let groups = [
    "Book Club", "Runners", "Bakers", "Board Games", "Choir", "Climbing", "Allotments", "Film Night", "Knitting Circle",
    "Cyclists", "Photo Walks", "Swimmers", "Hikers", "Supper Club",
]
private let channelNames = [
    "general", "introductions", "photos", "food", "pets", "music", "books", "events", "help", "off-topic", "plans",
    "gear", "routes", "recipes", "garden", "travel", "games", "movies", "art", "news", "lost-and-found", "carpool",
    "swap-shop", "birthdays", "wins", "random", "weekend", "late-night",
]

private let shortLines = [
    "lol", "same", "omg yes", "wait really?", "hahaha", "ok that's amazing", "noted", "100%", "this", "nooo", "honestly same",
    "brb", "good morning!", "night all 🌙", "on my way", "can't wait", "sounds good to me", "oh no", "ok fair", "love that",
    "thank you!!", "congrats!!", "yesss", "wait what", "i'm in", "count me out this time", "😂", "🥹", "🙌", "❤️",
]
private let activities = [
    "made pancakes", "finished the book", "walked the dog", "repotted the fern", "went for a run", "fixed the shelf",
    "tried the new bakery", "cleaned the whole kitchen", "watched the first episode", "planted the tulips",
    "baked bread", "rearranged the living room", "called my gran", "did the big shop", "learned a new song",
]
private let times = ["this morning", "last night", "after work", "on my lunch break", "just now", "earlier", "at like 6am"]
private let feelings = [
    "feel amazing", "regret nothing", "need a nap", "am very proud of myself", "might do it again tomorrow",
    "am now starving", "feel like a new person",
]
private let questions = [
    "free on saturday", "want to get lunch this week", "know a good plumber", "have a ladder i can borrow",
    "up for a walk later", "been to the new place on the corner", "watching the match tonight", "need anything from the shop",
]
private let subjects = [
    "the new café", "that recipe", "the last episode", "this weather", "the bus this morning", "my sourdough",
    "the park in autumn", "the farmers market", "that playlist", "the new bike path", "my neighbour's cat",
]
private let judgements = [
    "so good", "a bit overrated", "honestly perfect", "chaos", "underrated", "unhinged in the best way",
    "exactly what i needed", "a whole mood",
]
private let plans = [
    "picnic in the park", "movie night at mine", "bring snacks", "meet by the fountain", "car boot sale",
    "dinner at the noodle place", "early swim", "long walk by the river", "board games after",
]
private let surprises = [
    "i slept nine hours", "the cat learned to open doors", "i finished a whole puzzle", "the shop had my size",
    "it didn't rain", "my tomatoes are actually growing", "the bus was early",
]
private let reactionsOpeners = ["obsessed with", "not sure about", "thinking about", "still recovering from", "big fan of"]
private let reminders = [
    "bring a jacket", "the potluck is sunday", "return the library books", "water the plants", "it's sam's birthday soon",
    "rsvp for friday",
]
private let links = [
    "https://www.smallkitchenbigflavour.com/recipes/weeknight-noodles", "https://www.slowtravelnotes.com/coastal-walks",
    "https://smallhours.fm/episodes/the-missing-gnome", "https://notes.theporch.club/house-rules",
]
private let emoji = ["😂", "🥹", "✨", "🙌", "❤️", "🌱", "🍞", "☕", "🐸", "🎉", "😴", "👀", "🌧️", "🌞"]

private let things = [
    "walking boots", "a rice cooker", "houseplants", "a rain jacket", "board games", "notebooks", "a bike lock",
    "running shoes", "a cast iron pan", "a tent",
]
private let purposes = ["beginners", "a small flat", "rainy days", "a long trip", "a gift", "kids", "under 50"]
private let neededThings = ["a carpool on saturday", "a spare ladder", "someone to split a veg box", "a plant sitter", "a fourth for doubles"]
private let tasks = ["keep basil alive", "get wax out of fabric", "store fresh herbs", "fix a squeaky door", "pack light"]
private let categories = ["podcast", "book", "cozy game", "hiking trail", "soup", "comfort show"]
private let events = ["picnic", "park run", "potluck", "swap meet", "quiz night", "litter pick"]
private let postOpeners = [
    "Hi all!", "Quick question for everyone.", "Asking for a friend (me).", "Hoping someone here knows.", "Long-time lurker, first post.",
]
private let postClosers = ["Thanks in advance 🙏", "Any tips welcome!", "Happy to return the favour.", "Cheers!", "Let me know below 👇"]
