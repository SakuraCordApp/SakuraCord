import Foundation

/// Activities on the demo's launcher shelf: small games the simulator serves itself.
extension DemoConverter {
    struct DemoActivity {
        var username, name, summary: String
        var tags: [String]
        var limit: Int?
    }

    static let activities = [
        DemoActivity(username: "petalpass", name: "Petal Pass", summary: "Pass the petal around the room and see how high the count gets.",
                     tags: ["party", "casual"]),
        DemoActivity(username: "lanternlight", name: "Lantern Light", summary: "Light lanterns together, one tap at a time.",
                     tags: ["relaxing", "co-op"], limit: 8),
    ]

    mutating func addActivities() async {
        for activity in Self.activities {
            let id = await world.nextID(at: world.epoch.addingTimeInterval(-900 * 86_400))
            var bot = User(id: id, username: activity.username, globalName: activity.name)
            bot.bot = true
            bot.bio = activity.summary
            bot.avatar = await world.nextHash()
            await world.addUser(bot)
            if let avatar = bot.avatar { await world.registerAsset(avatar) }
            let cover = await world.nextHash()
            await world.registerAsset(cover)
            await world.addActivityApp(ActivityApp(id: id, summary: activity.summary, tags: activity.tags, maxParticipants: activity.limit, cover: cover))
        }
    }
}
