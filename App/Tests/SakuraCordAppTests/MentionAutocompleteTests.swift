import Foundation
import MessageRendering
@testable import SakuraCord
import SakuraCordModels
import Testing

@MainActor
struct MentionAutocompleteTests {
    @Test func testMentionAutocompleteContextQuotedAndUnquoted() throws {
        // 1. Quoted channel / post query with spaces
        let text1 = "check out #\"Release Notes\""
        let context1 = try #require(MentionAutocompleteContext(text: text1, selection: nil))
        #expect(context1.kind == .channel)
        #expect(context1.query == "Release Notes")
        #expect((text1 as NSString).substring(with: context1.range) == "#\"Release Notes\"")

        // 2. Unclosed quoted channel / post query while typing
        let text2 = "see #\"Release Notes"
        let context2 = try #require(MentionAutocompleteContext(text: text2, selection: nil))
        #expect(context2.kind == .channel)
        #expect(context2.query == "Release Notes")
        #expect((text2 as NSString).substring(with: context2.range) == "#\"Release Notes")

        // 3. Smart quotes (Unicode curly quotes)
        let text3 = "refer to #“Release Notes”"
        let context3 = try #require(MentionAutocompleteContext(text: text3, selection: nil))
        #expect(context3.kind == .channel)
        #expect(context3.query == "Release Notes")
        #expect((text3 as NSString).substring(with: context3.range) == "#“Release Notes”")

        // 4. Standard unquoted channel mention
        let text4 = "hello #release"
        let context4 = try #require(MentionAutocompleteContext(text: text4, selection: nil))
        #expect(context4.kind == .channel)
        #expect(context4.query == "release")
        #expect((text4 as NSString).substring(with: context4.range) == "#release")

        // 5. Bare #
        let text5 = "hello #"
        let context5 = try #require(MentionAutocompleteContext(text: text5, selection: nil))
        #expect(context5.kind == .channel)
        #expect(context5.query == "")
        #expect((text5 as NSString).substring(with: context5.range) == "#")

        // 6. Trailing space without quotes terminates autocomplete
        let text6 = "hello #release "
        #expect(MentionAutocompleteContext(text: text6, selection: nil) == nil)

        // 7. Member @ mention
        let text7 = "ping @member"
        let context7 = try #require(MentionAutocompleteContext(text: text7, selection: nil))
        #expect(context7.kind == .member)
        #expect(context7.query == "member")
        #expect((text7 as NSString).substring(with: context7.range) == "@member")
    }

    @Test func testChannelSuggestionsIncludesForumPosts() throws {
        let guildID = GuildID(rawValue: 100)
        let forumChannel = Channel(
            id: ChannelID(rawValue: 200),
            guildID: guildID,
            name: "forum-discussion",
            kind: .forum
        )
        let textChannel = Channel(
            id: ChannelID(rawValue: 201),
            guildID: guildID,
            name: "general",
            kind: .text
        )
        let forumPostThread = MessageThreadSummary(
            id: ChannelID(rawValue: 300),
            guildID: guildID,
            parentID: forumChannel.id,
            name: "Release Notes"
        )
        let otherThread = MessageThreadSummary(
            id: ChannelID(rawValue: 301),
            guildID: guildID,
            parentID: forumChannel.id,
            name: "Community Highlights"
        )
        let archivedThread = MessageThreadSummary(
            id: ChannelID(rawValue: 302),
            guildID: guildID,
            parentID: forumChannel.id,
            name: "Release Archive",
            isArchived: true
        )

        let suggestions = MentionAutocompleteSuggestionFactory.channelSuggestions(
            query: "release",
            channels: [forumChannel, textChannel],
            threads: [forumPostThread, otherThread, archivedThread],
            guilds: [:]
        )

        #expect(!suggestions.isEmpty)
        let match = try #require(suggestions.first)
        #expect(match.id == "thread:\(forumPostThread.id)")
        #expect(match.title == "Release Notes")
        #expect(match.detail == "forum-discussion")
        #expect(match.value == "<#\(forumPostThread.id)>")
        #expect(match.systemImage == "bubble.left.fill")
        #expect(!suggestions.contains { $0.id == "thread:\(archivedThread.id)" })
    }

    @Test func testChannelHeading() {
        #expect(MentionAutocompleteSuggestionFactory.channelHeading(query: "") == "TEXT CHANNELS")
        #expect(MentionAutocompleteSuggestionFactory.channelHeading(query: "release") == "TEXT CHANNELS MATCHING #RELEASE")
    }
}
