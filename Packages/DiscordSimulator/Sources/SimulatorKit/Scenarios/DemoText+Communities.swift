import Foundation

/// Kinds of community a real account belongs to, each with its own names,
/// channels, roles, emoji and things people talk about.
public enum CommunityKind: String, Sendable, CaseIterable {
    case gaming, art, study, music, tech, fandom, local, creator, hub, friends

    /// Huge servers are public hubs; tiny ones are friends and local groups.
    static func pick(memberCount: Int, _ rng: inout SeededRandom) -> CommunityKind {
        switch memberCount {
        case 100_000...: rng.pick([.hub, .gaming, .gaming, .fandom, .creator, .tech])
        case 5_000...: rng.pick([.gaming, .fandom, .creator, .tech, .art, .music, .hub])
        case 200...: rng.pick([.gaming, .art, .study, .music, .tech, .fandom, .creator, .local])
        default: rng.pick([.friends, .friends, .local, .study, .gaming])
        }
    }

    var bank: CommunityBank {
        switch self {
        case .gaming: .gaming
        case .art: .art
        case .study: .study
        case .music: .music
        case .tech: .tech
        case .fandom: .fandom
        case .local: .local
        case .creator: .creator
        case .hub: .hub
        case .friends: .friends
        }
    }
}

struct CommunityBank: Sendable {
    var names: [String]
    var nameSuffixes: [String]
    var categories: [String]
    var text: [String]
    var voice: [String]
    var forums: [String]
    var announcements: [String]
    var roles: [String]
    var emoji: [String]
    /// Chat lines with `{thing}` filled from `things`.
    var lines: [String]
    var things: [String]
}

public extension DemoText {
    /// A server name for a community.
    static func communityName(_ kind: CommunityKind, _ rng: inout SeededRandom) -> String {
        "\(rng.pick(kind.bank.names))\(rng.pick(kind.bank.nameSuffixes))"
    }

    /// A chat line that fits the community, mixed with ordinary chatter.
    static func communityMessage(_ kind: CommunityKind, _ rng: inout SeededRandom) -> String {
        guard rng.chance(0.55) else { return message(&rng) }
        let bank = kind.bank
        var line = rng.pick(bank.lines)
        while let range = line.range(of: "{thing}") { line.replaceSubrange(range, with: rng.pick(bank.things)) }
        return line
    }

    /// The `index`th name from `names`, numbered once the bank runs out, so names stay unique.
    static func numbered(_ names: [String], _ index: Int) -> String {
        let round = index / names.count
        return round == 0 ? names[index % names.count] : "\(names[index % names.count])-\(round + 1)"
    }
}

extension CommunityBank {
    static let gaming = CommunityBank(
        names: ["Pixel", "Respawn", "Critical", "Lootbox", "Night Raid", "Co-op", "Speedrun", "Side Quest", "Low Ping", "Boss Rush"],
        nameSuffixes: [" Club", " Collective", " Hangout", " Squad", " HQ", " Lobby", " Guild"],
        categories: ["Info", "Community", "Looking for Group", "Game Talk", "Voice", "Clips", "Events", "Archive"],
        text: ["general", "lfg", "clips", "screenshots", "patch-notes", "builds", "tips-and-tricks", "memes", "off-topic", "trading",
               "bug-reports", "speedruns", "fan-art", "setups", "self-promo", "bot-commands", "suggestions", "tournaments"],
        voice: ["Lobby", "Squad 1", "Squad 2", "Duo Queue", "Chill Room", "AFK", "Ranked Grind", "Tournament Stage"],
        forums: ["help-forum", "build-guides", "lfg-board", "feedback"],
        announcements: ["announcements", "updates", "server-news"],
        roles: ["Admin", "Moderator", "Helper", "Veteran", "Tournament Crew", "Streamer", "Booster", "Member", "Newcomer", "PC", "Console",
                "Mobile", "EU", "NA", "Asia", "Ranked", "Casual", "Event Pings", "Patch Pings", "Artist"],
        emoji: ["gg", "pog", "rip", "clutch", "lag", "headshot", "noob", "victory", "loot", "respawn", "crit", "tank", "heal", "ez"],
        lines: ["anyone up for a few rounds of {thing}?", "the new {thing} patch is wild", "finally beat the {thing} boss 🎉",
                "is {thing} worth it on sale?", "lfg {thing}, need 2 more", "my {thing} build is finally coming together",
                "that {thing} clip from last night 😂", "servers are lagging again for {thing}?", "ranked in {thing} is pain today"],
        things: ["raid", "the new map", "co-op", "ranked", "the expansion", "the dungeon", "the speedrun route", "the event", "the beta"]
    )

    static let art = CommunityBank(
        names: ["Sketchbook", "Ink & Paper", "Palette", "Brushwork", "Doodle", "Studio Nine", "Linework", "Colour Theory"],
        nameSuffixes: [" Club", " Collective", " Studio", " Circle", " Corner"],
        categories: ["Welcome", "Share Your Work", "Learning", "Critique", "Commissions", "Voice", "Events"],
        text: ["general", "share-your-art", "wips", "sketches", "digital", "traditional", "references", "critique", "resources",
               "commissions", "art-prompts", "studies", "inspiration", "tools-and-gear", "off-topic"],
        voice: ["Draw Together", "Quiet Studio", "Critique Room"],
        forums: ["critique-requests", "tutorials", "questions"],
        announcements: ["announcements", "challenges"],
        roles: ["Admin", "Mod", "Mentor", "Featured Artist", "Commissions Open", "Digital", "Traditional", "3D", "Booster", "Member",
                "Challenge Pings", "Livestream Pings"],
        emoji: ["brush", "palette", "sparkles", "pencil", "wip", "chef", "inspired", "clap", "colour", "sketch"],
        lines: ["here's my {thing} from today, still a wip", "any tips for {thing}?", "finally finished the {thing} 😭",
                "this week's prompt is {thing}", "trying a new {thing} brush", "love the colours on that {thing}"],
        things: ["portrait", "landscape study", "character design", "gesture sketches", "watercolour", "lineart", "background", "comic page"]
    )

    static let study = CommunityBank(
        names: ["Study", "Late Night Notes", "Library", "Focus", "Flashcard", "Exam Season", "Lecture Hall", "Pomodoro"],
        nameSuffixes: [" Group", " Room", " Hall", " Buddies", " Club"],
        categories: ["Info", "Subjects", "Study Rooms", "Resources", "Chill"],
        text: ["general", "homework-help", "maths", "biology", "chemistry", "languages", "history", "coding", "accountability",
               "resources", "exam-prep", "wins", "off-topic"],
        voice: ["Silent Study", "Study Room 1", "Study Room 2", "Pomodoro", "Group Revision"],
        forums: ["questions", "notes-exchange"],
        announcements: ["announcements"],
        roles: ["Admin", "Mod", "Tutor", "Night Owl", "Early Bird", "Member", "Exam Season", "Booster"],
        emoji: ["focus", "coffee", "brain", "books", "done", "streak", "tired", "pomodoro"],
        lines: ["anyone want to do a {thing} session?", "finally finished my {thing} notes", "{thing} exam tomorrow, wish me luck",
                "does anyone understand {thing}?", "3 hours of {thing} done ✅", "taking a break from {thing}"],
        things: ["revision", "organic chem", "statistics", "essay", "vocab", "lab report", "past paper", "calculus"]
    )

    static let music = CommunityBank(
        names: ["Bandroom", "Low End", "Mixdown", "Chord", "Vinyl", "Open Mic", "Synth", "Bedroom Producers"],
        nameSuffixes: [" Club", " Collective", " Lounge", " Society", " Hangout"],
        categories: ["Info", "Music Talk", "Share", "Production", "Listening Parties", "Voice"],
        text: ["general", "now-playing", "recommendations", "share-your-music", "production", "gear", "theory", "collabs",
               "feedback", "concerts", "vinyl", "playlists", "off-topic"],
        voice: ["Listening Party", "Jam Room", "Studio", "Chill"],
        forums: ["feedback-forum", "gear-help"],
        announcements: ["announcements", "releases"],
        roles: ["Admin", "Mod", "Producer", "Vocalist", "Guitar", "Keys", "Drums", "DJ", "Listener", "Booster", "Release Pings"],
        emoji: ["vinyl", "headphones", "fire", "bop", "bass", "mic", "note", "dance"],
        lines: ["on repeat today: {thing}", "anyone been to see {thing} live?", "finished a {thing} track, feedback welcome",
                "best {thing} you've heard this year?", "{thing} album was so good", "working on a {thing} loop"],
        things: ["lo-fi", "the new album", "synthwave", "jazz", "a b-side", "drum and bass", "acoustic", "that remix"]
    )

    static let tech = CommunityBank(
        names: ["Dev", "Open Source", "Homelab", "Terminal", "Build", "Stack", "Byte", "Hack Night"],
        nameSuffixes: [" Hub", " Community", " Lounge", " Collective", " Crew"],
        categories: ["Info", "Discussion", "Help", "Projects", "Off Topic", "Voice"],
        text: ["general", "help", "show-and-tell", "frontend", "backend", "devops", "homelab", "jobs", "rust", "python", "swift",
               "linux", "hardware", "links", "random"],
        voice: ["Pairing", "Office Hours", "Hangout"],
        forums: ["help-forum", "showcase", "rfcs"],
        announcements: ["announcements", "releases", "changelog"],
        roles: ["Admin", "Mod", "Maintainer", "Contributor", "Helper", "Hiring", "Booster", "Member", "Release Pings"],
        emoji: ["shipit", "bug", "lgtm", "rubberduck", "coffee", "fire", "thinking", "merged"],
        lines: ["anyone else seeing {thing} after the update?", "finally got {thing} working", "hot take: {thing} is overrated",
                "shipped the {thing} today 🚀", "how do you all handle {thing}?", "spent all day debugging {thing}"],
        things: ["the build", "dark mode", "the homelab", "a flaky test", "the migration", "the new release", "caching", "the side project"]
    )

    static let fandom = CommunityBank(
        names: ["Starlight", "Moonrise", "Afterglow", "Chapter One", "Fan Theories", "Episode", "Canon", "Midnight"],
        nameSuffixes: [" Fan Club", " Community", " Society", " Hangout", " Archive"],
        categories: ["Info", "Discussion", "Fan Works", "Spoilers", "Media", "Voice"],
        text: ["general", "episode-talk", "theories", "spoilers", "fan-art", "fanfic", "merch", "cosplay", "memes", "rewatch",
               "news", "off-topic", "polls"],
        voice: ["Watch Party", "Theory Corner", "Hangout"],
        forums: ["theories-forum", "recommendations"],
        announcements: ["announcements", "news-feed"],
        roles: ["Admin", "Mod", "Theorist", "Artist", "Writer", "Cosplayer", "Booster", "Member", "Spoiler Pings", "Watch Party Pings"],
        emoji: ["cry", "heart", "shook", "theory", "ship", "popcorn", "wave", "eyes"],
        lines: ["that {thing} reveal though", "rewatching {thing} for the third time", "my theory about {thing} 👀",
                "no spoilers but {thing} 😭", "who's coming to the {thing} watch party?", "the {thing} merch is finally out"],
        things: ["finale", "season two", "the movie", "chapter 40", "the trailer", "the side story", "the soundtrack", "the special"]
    )

    static let local = CommunityBank(
        names: ["Riverside", "Old Town", "Northside", "Harbour", "Mill Road", "Cedar Park", "Eastgate", "Hilltop"],
        nameSuffixes: [" Neighbours", " Community", " Runners", " Swap Shop", " Allotments", " Climbing", " Choir"],
        categories: ["Welcome", "Around Town", "Events", "Buy & Sell", "Voice"],
        text: ["general", "events", "lost-and-found", "recommendations", "for-sale", "free-stuff", "carpool", "photos", "pets",
               "food", "news", "off-topic"],
        voice: ["Town Hall", "Hangout"],
        forums: ["questions", "marketplace"],
        announcements: ["announcements", "notices"],
        roles: ["Organiser", "Mod", "Volunteer", "Neighbour", "Booster", "Event Pings"],
        emoji: ["wave", "sun", "rain", "bike", "tree", "coffee", "dog", "cake"],
        lines: ["anyone going to {thing} this weekend?", "{thing} is closed today fyi", "lost a glove near {thing}",
                "who recommended {thing}? it was great", "{thing} meetup moved to 7"],
        things: ["the market", "the park", "the library", "the bakery", "the river path", "the community garden", "the quiz night"]
    )

    static let creator = CommunityBank(
        names: ["Cozy Corner", "Late Stream", "The Den", "Pocket", "Studio", "Comfy", "Sunday Stream", "Chat"],
        nameSuffixes: [" Community", " Crew", " Hangout", " Fam", " Club"],
        categories: ["Info", "Community", "Stream", "Creative", "Voice", "Events"],
        text: ["general", "stream-chat", "clips", "fan-art", "suggestions", "pets", "food", "selfies", "music", "memes",
               "off-topic", "bot-commands"],
        voice: ["Community Hangout", "Stream Watch", "Game Night"],
        forums: ["suggestions-forum", "creations"],
        announcements: ["announcements", "going-live", "uploads"],
        roles: ["Mod", "VIP", "Subscriber", "Booster", "Regular", "Artist", "Member", "Live Pings", "Upload Pings"],
        emoji: ["hype", "love", "lul", "wave", "comfy", "pat", "sip", "dance", "salute"],
        lines: ["that {thing} on stream was hilarious", "when's the next {thing}?", "made some fan art of {thing}",
                "clip of {thing} 😂", "can't make the {thing} tonight, catch the vod later"],
        things: ["the cooking stream", "the q&a", "the charity stream", "the collab", "the subathon", "game night", "the new intro"]
    )

    static let hub = CommunityBank(
        names: ["The Lounge", "Hangout", "Chill Zone", "Global", "Commons", "Plaza", "Town Square", "Big Room"],
        nameSuffixes: ["", " Community", " Hub", " Network", " Central"],
        categories: ["Start Here", "Chat", "Interests", "Media", "Voice", "Events", "Support"],
        text: ["general", "general-2", "introductions", "memes", "pets", "food", "music", "gaming", "movies", "sports", "art",
               "selfies", "advice", "vent", "bot-commands", "counting", "media", "questions"],
        voice: ["General VC", "Chill VC", "Gaming VC", "Music VC", "Late Night", "AFK"],
        forums: ["advice-forum", "recommendations", "support"],
        announcements: ["announcements", "events", "partners"],
        roles: ["Owner", "Admin", "Senior Mod", "Mod", "Trial Mod", "Event Host", "Partner", "Booster", "Level 50", "Level 30",
                "Level 10", "Member", "He/Him", "She/Her", "They/Them", "Gamer", "Artist", "Music", "Event Pings", "Giveaway Pings"],
        emoji: ["wave", "lol", "pog", "sad", "hype", "yes", "no", "think", "love", "angry", "cool", "party"],
        lines: ["good morning everyone ☀️", "what's everyone up to {thing}?", "anyone else from {thing}?",
                "{thing} giveaway when 👀", "rate my {thing}", "who's around {thing}?"],
        things: ["tonight", "this weekend", "europe", "the event", "lunch", "setup", "the stage"]
    )

    static let friends = CommunityBank(
        names: ["the group chat", "Flat 4", "Sunday Club", "Roomies", "Old Uni Lot", "Book Swap", "Trip Planning", "The Usual"],
        nameSuffixes: ["", " 🌙", " ✨", " HQ", " (official)"],
        categories: ["Chat", "Plans", "Voice"],
        text: ["general", "plans", "photos", "memes", "food", "music", "games", "trip"],
        voice: ["Hangout", "Gaming"],
        forums: ["plans-forum"],
        announcements: ["important"],
        roles: ["admin", "the usual suspects", "trip crew", "bots"],
        emoji: ["lol", "cry", "love", "yes", "pizza", "sleepy"],
        lines: ["are we still on for {thing}?", "who's bringing what to {thing}", "photos from {thing} 📸", "{thing} again soon pls"],
        things: ["friday", "the trip", "dinner", "game night", "the picnic", "the birthday"]
    )
}
