@testable import SakuraCord
import AppKit
import Testing

@MainActor
@Test(arguments: [
    ("**hello world**", "hello", "**", "hello **world**"),
    ("**hello world**", "world", "**", "**hello** world"),
    ("**red green blue**", "green", "**", "**red** green **blue**"),
    ("***red green blue***", "green", "**", "***red*** *green* ***blue***"),
    ("**red __green blue__ tail**", "green", "**", "**red** __green__ **__blue__ tail**"),
    ("*__**red green blue**__*", "green", "*", "*__**red**__* __**green**__ *__**blue**__*"),
    ("__red green blue__", "green", "__", "__red__ green __blue__"),
    ("**ab🌸cd**", "🌸", "**", "**ab**🌸**cd**"),
    ("**hello <@123> world**", "hello", "**", "hello **<@123> world**"),
    ("**text [label*](https://example.com) end**", "text", "**", "text **[label*](https://example.com) end**"),
    ("**bold *literal** then *italic*", "bold", "**", "bold ***literal** then *italic*")
])
func `composer partial formatting preserves other text styles attachments and undo`(
    _ source: String, _ selected: String, _ marker: String, _ expected: String
) {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let view = ComposerNSTextView(frame: window.contentView!.bounds)
    view.allowsUndo = true
    view.plainTextStyle = .composer(.systemFont(ofSize: 15))
    window.contentView = view
    window.makeFirstResponder(view)
    view.textStorage?.setAttributedString(ComposerEmojiAttributedText.make(source))
    view.setSelectedRange((view.string as NSString).range(of: selected))
    view.wrapSelectionInMarkdown(marker)
    #expect(ComposerEmojiAttributedText.serialize(view.attributedString()) == expected)
    #expect((view.string as NSString).substring(with: view.selectedRange()) == selected)
    let attributes = view.textStorage?.attributes(at: view.selectedRange().location, effectiveRange: nil)
    let traits = (attributes?[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
    if marker == "**" { #expect(!traits.contains(.bold)) }
    if marker == "*" { #expect(!traits.contains(.italic)) }
    if marker == "__" { #expect(attributes?[.underlineStyle] == nil) }
    view.undoManager?.undo()
    #expect(ComposerEmojiAttributedText.serialize(view.attributedString()) == source)
    view.undoManager?.redo()
    #expect(ComposerEmojiAttributedText.serialize(view.attributedString()) == expected)
}

@MainActor
@Test func `composer formatting applies to the selection even inside code and links`() {
    let view = ComposerNSTextView()
    for (source, selected, expected) in [
        ("**before [hello world](https://example.com) after**", "hello", "**before [**hello **world](https://example.com) after**"),
        ("`hello world`", "hello", "`**hello** world`"),
        ("```swift\nhello world\n```", "hello", "```swift\n**hello** world\n```"),
        ("[label](https://example.com)", "example", "[label](https://**example**.com)"),
        ("<https://example.com>", "example", "<https://**example**.com>"),
        ("https://example.com", "example", "https://**example**.com")
    ] {
        view.string = source
        view.setSelectedRange((source as NSString).range(of: selected))
        view.wrapSelectionInMarkdown("**")
        #expect(view.string == expected)
        #expect((view.string as NSString).substring(with: view.selectedRange()) == selected)
    }
}

// Choosing a suggestion replaces `range` with the mention, so a wrong range
// would send leftover or deleted message text.
@MainActor
@Test(arguments: [
    ("check out #\"Release Notes\"", nil, "Release Notes", "#\"Release Notes\""),
    ("check out #\"Release Notes\" today", 19, "Release", "#\"Release Notes\""),
    ("see #\"Release Notes", nil, "Release Notes", "#\"Release Notes"),
    ("refer to #“Release Notes”", nil, "Release Notes", "#“Release Notes”"),
    (##"check #"Release \"Notes\" Updates""##, nil, #"Release "Notes" Updates"#, ##"#"Release \"Notes\" Updates""##),
    (##"check #"Release \"Notes\" Updates" now"##, 15, "Release", ##"#"Release \"Notes\" Updates""##),
    (##"check #"Release \\" and say "hello" today"##, 17, #"Release \"#, ##"#"Release \\""##),
    ("#\"C:\\\nnext \"line\"", 5, "C:\\", "#\"C:\\"),
    ("hello #release", nil, "release", "#release")
] as [(String, Int?, String, String)])
func `channel mention autocomplete covers the whole quoted token`(
    _ text: String, _ cursor: Int?, _ query: String, _ token: String
) throws {
    let context = try #require(MentionAutocompleteContext(
        text: text, selection: cursor.map { NSRange(location: $0, length: 0) }
    ))
    #expect(context.kind == .channel)
    #expect(context.query == query)
    #expect((text as NSString).substring(with: context.range) == token)
}

@MainActor
@Test func `channel mention autocomplete closes at a line break`() {
    let text = "check #\"Release\n Notes\" now"
    let caret = ("check #\"Release\n" as NSString).length
    #expect(MentionAutocompleteContext(text: text, selection: NSRange(location: caret, length: 0)) == nil)
}
