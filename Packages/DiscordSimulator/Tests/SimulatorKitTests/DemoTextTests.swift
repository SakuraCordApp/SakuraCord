import Foundation
@testable import SimulatorKit
import Testing

struct DemoTextTests {
    @Test func generatedUsernamesNeverCollide() {
        // Past the 16,592 combinations of the name banks, so numbered rounds are covered.
        let usernames = (0 ..< 20_000).map { DemoText.person(index: $0).username }
        #expect(Set(usernames).count == usernames.count)
        #expect(Set(usernames).isDisjoint(with: DemoContent.people.map(\.username)))
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.")
        #expect(usernames.allSatisfy { Set($0).isSubset(of: allowed) })
    }

    @Test func peopleAreDeterministic() {
        #expect(DemoText.person(index: 4_321) == DemoText.person(index: 4_321))
        #expect(DemoText.person(index: 1).avatar != DemoText.person(index: 2).avatar)
    }

    @Test func namesAreUnique() {
        let servers = (0 ..< 500).map(DemoText.serverName(index:))
        #expect(Set(servers).count == servers.count)
        let channels = (0 ..< 200).map(DemoText.channelName(index:))
        #expect(Set(channels).count == channels.count)
    }

    @Test func messagesAreDeterministicAndVaried() {
        func lines(_ seed: UInt64) -> [String] {
            var rng = SeededRandom(seed: seed)
            return (0 ..< 300).map { _ in DemoText.message(&rng) }
        }
        #expect(lines(7) == lines(7))
        #expect(lines(7) != lines(8))
        let sample = lines(42)
        #expect(Set(sample).count > 200)
        #expect(sample.contains { $0.count < 12 })
        #expect(sample.contains { $0.contains("\n") })
    }

    @Test func forumPostsAreDeterministic() {
        var first = SeededRandom(seed: 3)
        var second = SeededRandom(seed: 3)
        for _ in 0 ..< 50 {
            #expect(DemoText.forumPostTitle(&first) == DemoText.forumPostTitle(&second))
            #expect(DemoText.forumPostBody(&first) == DemoText.forumPostBody(&second))
        }
    }

    @Test func textStaysInWorld() {
        var rng = SeededRandom(seed: 99)
        var text = (0 ..< 5_000).map { _ in DemoText.message(&rng) }
        text += (0 ..< 500).flatMap { _ in [DemoText.forumPostTitle(&rng), DemoText.forumPostBody(&rng)] }
        text += (0 ..< 2_000).flatMap { index in
            let person = DemoText.person(index: index)
            return [person.displayName, person.bio, person.presence.customStatus ?? "", DemoText.serverName(index: index)]
        }
        for line in text {
            let lowered = line.lowercased()
            for word in ["sakuracord", "simulator", "benchmark", "test", "discord"] {
                #expect(!lowered.contains(word), "\"\(line)\" mentions \(word)")
            }
        }
    }
}
