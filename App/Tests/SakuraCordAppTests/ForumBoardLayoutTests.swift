import AppKit
import SakuraCordModels
import Testing
@testable import SakuraCord

/// The forum board's central promise: data that arrives after a post first
/// appears (starter message, thumbnail, reactions) never moves or resizes a card.
@MainActor
@Test(arguments: [ForumLayout.list, .gallery])
func `forum board geometry ignores late post data`(mode: ForumLayout) {
    let channelID = ChannelID(rawValue: 900)
    let author = User(id: UserID(rawValue: 1), username: "ada", displayName: "Ada")
    func post(_ index: UInt64, hydrated: Bool) -> ForumPost {
        let id = ChannelID(rawValue: 1_000 + index)
        let thread = MessageThreadSummary(
            id: id,
            parentID: channelID,
            name: index.isMultiple(of: 2)
                ? "A long forum post title that wraps onto a second line at narrow widths"
                : "Short title",
            messageCount: 3,
            appliedTagIDs: index.isMultiple(of: 3) ? [ForumTagID(rawValue: 7)] : []
        )
        guard hydrated else { return ForumPost(thread: thread) }
        let starter = Message(
            id: MessageID(rawValue: id.rawValue),
            channelID: id,
            author: author,
            content: String(repeating: "Starter text that fills the excerpt. ", count: 8),
            attachments: [Attachment(
                id: "a\(index)",
                filename: "shot.png",
                url: URL(string: "https://cdn.example.com/\(index).png")!,
                mediaType: "image/png"
            )],
            reactions: [Reaction(emoji: "👍", count: 4)]
        )
        return ForumPost(thread: thread, owner: author, firstMessage: starter, mostRecentMessage: starter)
    }
    let metrics = ForumBoardMetrics.current()
    let counter = ForumTitleLineCounter(font: metrics.titleFont, maximumLines: metrics.maximumTitleLines)
    func layout(hydrated: Bool, width: CGFloat) -> [CGRect] {
        let items = (0 ..< 12).map { ForumBoardItem.post(ForumCardGeometryInput(post: post($0, hydrated: hydrated))) }
        return ForumBoardLayout.make(
            items: items,
            mode: mode,
            width: width,
            metrics: metrics,
            titleLines: { counter.lines($0, width: $1) }
        ).entries.map(\.frame)
    }
    for width: CGFloat in [360, 720, 1_280] {
        #expect(layout(hydrated: false, width: width) == layout(hydrated: true, width: width))
    }
}

/// Card heights come from title line counts; the width-independent fast path
/// must agree with the typesetter at every width, or a card could change
/// height when the board resizes.
@MainActor
@Test
func `forum title line counts match the typesetter at every width`() {
    let font = ForumBoardMetrics.current().titleFont
    let counter = ForumTitleLineCounter(font: font, maximumLines: 2)
    let titles = [
        "Short title",
        "A long forum post title that wraps onto a second line at narrow widths",
        "Supercalifragilisticexpialidocious-without-any-break-opportunities-at-all",
        "Trailing spaces stay out of the measurement   ",
        "Emoji 🎉 and CJK 日本語のタイトル mixed in",
        "W",
        "Hi",
    ]
    for title in titles {
        for width in [1, 2, 5, 10, 20] + Array(stride(from: 40, through: 900, by: 7)) {
            let expected = ForumTitleLineCounter.count(title, width: CGFloat(width), font: font, maximumLines: 2)
            #expect(counter.lines(title, width: CGFloat(width)) == expected, "\(title) at \(width)")
        }
    }
}

@MainActor
@Test
func `gallery arrow keys follow rows across sections with different column counts`() {
    let width: CGFloat = 100
    // One recent card, then an Older Posts section of three columns.
    let frames = [
        CGRect(x: 0, y: 0, width: 3 * width, height: 50),
        CGRect(x: 0, y: 100, width: width, height: 50),
        CGRect(x: width, y: 100, width: width, height: 50),
        CGRect(x: 2 * width, y: 100, width: width, height: 50),
        CGRect(x: 0, y: 200, width: width, height: 50),
        CGRect(x: width, y: 200, width: width, height: 50)
    ]
    #expect(ForumBoardLayout.adjacentRowIndex(from: 0, down: true, in: frames) == 2)
    #expect(ForumBoardLayout.adjacentRowIndex(from: 3, down: true, in: frames) == 5)
    #expect(ForumBoardLayout.adjacentRowIndex(from: 5, down: false, in: frames) == 2)
    #expect(ForumBoardLayout.adjacentRowIndex(from: 3, down: false, in: frames) == 0)
    #expect(ForumBoardLayout.adjacentRowIndex(from: 4, down: true, in: frames) == 5)
    #expect(ForumBoardLayout.adjacentRowIndex(from: 0, down: false, in: frames) == 0)
}
