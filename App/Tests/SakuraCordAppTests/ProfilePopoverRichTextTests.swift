import AppKit
import MessageRendering
@testable import SakuraCord
import SakuraCordModels
import Testing

@MainActor
@Suite("Profile Popover Rich Text Tests")
struct ProfilePopoverRichTextTests {
    @Test func `profile inline text renders discord markdown styling`() throws {
        let source = "**bold** *italic* ~~strike~~ `code`"
        let font = NSFont.systemFont(ofSize: 14)
        let attributed = ProfileInlineAttributedText.make(
            source: source,
            font: font,
            color: .labelColor,
            emojiImages: [:],
            stylesLinks: true
        )

        let string = attributed.string
        #expect(string.contains("bold"))
        #expect(string.contains("italic"))
        #expect(string.contains("strike"))
        #expect(string.contains("code"))
        #expect(!string.contains("**"))
        #expect(!string.contains("~~"))

        // Check bold font
        let boldRange = (string as NSString).range(of: "bold")
        let boldFont = try #require(attributed.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont)
        #expect(NSFontManager.shared.traits(of: boldFont).contains(.boldFontMask))

        // Check strikethrough
        let strikeRange = (string as NSString).range(of: "strike")
        let strikethrough = attributed.attribute(.strikethroughStyle, at: strikeRange.location, effectiveRange: nil) as? Int
        #expect(strikethrough == NSUnderlineStyle.single.rawValue)

        // Check inline code
        let codeRange = (string as NSString).range(of: "code")
        let isCode = attributed.attribute(.discordMarkdownInlineCode, at: codeRange.location, effectiveRange: nil) != nil
        #expect(isCode)
    }

    @Test func `profile inline text renders timestamps as mention attachments with live date formatting`() throws {
        let timestampSeconds: Int64 = 1_700_000_000
        let source = "Joined <t:\(timestampSeconds):R> and active"
        let font = NSFont.systemFont(ofSize: 14)
        let baseDate = Date(timeIntervalSince1970: TimeInterval(timestampSeconds + 120)) // 2 minutes after

        let attributed = ProfileInlineAttributedText.make(
            source: source,
            font: font,
            color: .labelColor,
            emojiImages: [:],
            stylesLinks: false,
            date: baseDate
        )

        var foundAttachment: MentionTextAttachment?
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if let attachment = value as? MentionTextAttachment, attachment.presentation.isTimestamp {
                foundAttachment = attachment
            }
        }

        let attachment = try #require(foundAttachment)
        #expect(attachment.presentation.rawToken == "<t:\(timestampSeconds):R>")
        #expect(attachment.presentation.isTimestamp)

        let expectedLabel = DiscordTimestampToken(seconds: timestampSeconds, style: .relative).formatted(relativeTo: baseDate)
        #expect(attachment.presentation.label == expectedLabel)

        // Ticking the clock to 1 hour later
        let laterDate = Date(timeIntervalSince1970: TimeInterval(timestampSeconds + 3600))
        let refreshed = ProfileInlineAttributedText.make(
            source: source,
            font: font,
            color: .labelColor,
            emojiImages: [:],
            stylesLinks: false,
            date: laterDate
        )

        var laterAttachment: MentionTextAttachment?
        refreshed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: refreshed.length)) { value, _, _ in
            if let attachment = value as? MentionTextAttachment, attachment.presentation.isTimestamp {
                laterAttachment = attachment
            }
        }

        let refreshedAttachment = try #require(laterAttachment)
        let expectedLaterLabel = DiscordTimestampToken(seconds: timestampSeconds, style: .relative).formatted(relativeTo: laterDate)
        #expect(refreshedAttachment.presentation.label == expectedLaterLabel)
        #expect(refreshedAttachment.presentation.label != attachment.presentation.label)
    }

    @Test func `profile inline text renders custom static and animated emojis`() throws {
        let source = "Hello <:custom_pepe:12345678> and <a:party_blob:87654321>!"
        let font = NSFont.systemFont(ofSize: 14)
        let attributed = ProfileInlineAttributedText.make(
            source: source,
            font: font,
            color: .labelColor,
            emojiImages: [:],
            stylesLinks: false
        )

        var tokens: [String] = []
        attributed.enumerateAttribute(.discordEmojiToken, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if let token = value as? String {
                tokens.append(token)
            }
        }

        #expect(tokens.contains("<:custom_pepe:12345678>"))
        #expect(tokens.contains("<a:party_blob:87654321>"))
    }

    @Test func `profile inline text conceals and reveals spoilers`() throws {
        let source = "Before ||hidden text|| after"
        let font = NSFont.systemFont(ofSize: 14)

        // Initially concealed
        let concealed = ProfileInlineAttributedText.make(
            source: source,
            font: font,
            color: .labelColor,
            emojiImages: [:],
            stylesLinks: false,
            revealedSpoilerLocations: []
        )

        var hasSpoilerAttribute = false
        concealed.enumerateAttribute(.discordMarkdownSpoiler, in: NSRange(location: 0, length: concealed.length)) { value, _, _ in
            if value != nil { hasSpoilerAttribute = true }
        }
        #expect(hasSpoilerAttribute)

        // Revealed at location
        let spoilerLocation = (concealed.string as NSString).range(of: "hidden text").location
        let revealed = ProfileInlineAttributedText.make(
            source: source,
            font: font,
            color: .labelColor,
            emojiImages: [:],
            stylesLinks: false,
            revealedSpoilerLocations: [spoilerLocation]
        )

        var revealedHasSpoiler = false
        revealed.enumerateAttribute(.discordMarkdownSpoiler, in: NSRange(location: 0, length: revealed.length)) { value, _, _ in
            if value != nil { revealedHasSpoiler = true }
        }
        #expect(!revealedHasSpoiler)
    }

    @Test func `profile inline text styles markdown links`() throws {
        let source = "Check out [Sakura](https://sakuracord.dev) now!"
        let font = NSFont.systemFont(ofSize: 14)
        let attributed = ProfileInlineAttributedText.make(
            source: source,
            font: font,
            color: .labelColor,
            emojiImages: [:],
            stylesLinks: true
        )

        let string = attributed.string
        #expect(string.contains("Sakura"))
        #expect(!string.contains("[Sakura]"))

        let linkRange = (string as NSString).range(of: "Sakura")
        let linkURL = try #require(attributed.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL)
        #expect(linkURL.absoluteString == "https://sakuracord.dev")
    }

    @Test func `profile editable bio preserves markdown delimiters and serializes accurately`() {
        let source = "**bold** <:pepe:123456> *italic*"
        let font = NSFont.systemFont(ofSize: 14)
        let editable = ProfileInlineAttributedText.makeEditable(
            source: source,
            font: font,
            color: .labelColor,
            emojiImages: [:]
        )

        let serialized = ComposerEmojiAttributedText.serialize(editable)
        #expect(serialized == source)
    }

    @Test func `profile inline text renders triple backtick code blocks with block attribute and does not link urls inside`() throws {
        let source = "Intro:\n```swift\nlet website = \"https://sakuracord.dev\"\nprint(website)\n```\nOutro `https://inline.link`"
        let font = NSFont.systemFont(ofSize: 14)
        let attributed = ProfileInlineAttributedText.make(
            source: source,
            font: font,
            color: .labelColor,
            emojiImages: [:],
            stylesLinks: true
        )

        let string = attributed.string
        #expect(string.contains("let website"))
        #expect(string.contains("print(website)"))
        #expect(!string.contains("```"))

        // Verify code block lines have .discordMarkdownBlock == "code"
        let codeRange = (string as NSString).range(of: "let website")
        let blockAttribute = attributed.attribute(.discordMarkdownBlock, at: codeRange.location, effectiveRange: nil) as? String
        #expect(blockAttribute == "code")

        // Verify font is monospaced
        let codeFont = try #require(attributed.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont)
        #expect(codeFont.fontDescriptor.symbolicTraits.contains(.monoSpace))

        // Verify URLs inside code block and inline code are not autolinked
        let blockUrlRange = (string as NSString).range(of: "https://sakuracord.dev")
        #expect(attributed.attribute(.link, at: blockUrlRange.location, effectiveRange: nil) == nil)

        let inlineUrlRange = (string as NSString).range(of: "https://inline.link")
        #expect(attributed.attribute(.link, at: inlineUrlRange.location, effectiveRange: nil) == nil)
        #expect(attributed.attribute(.discordMarkdownInlineCode, at: inlineUrlRange.location, effectiveRange: nil) != nil)
    }

    @Test func `profile inline text renders inline fences and trailing fences without language id`() throws {
        let source = "```**focus mode** • back\n<t:1750000000:r> :rocket:```"
        let font = NSFont.systemFont(ofSize: 14)
        let attributed = ProfileInlineAttributedText.make(
            source: source,
            font: font,
            color: .labelColor,
            emojiImages: [:],
            stylesLinks: false
        )

        let string = attributed.string
        #expect(string.contains("**focus mode** • back"))
        #expect(string.contains("<t:1750000000:r> :rocket:"))
        #expect(!string.contains("```"))

        let range1 = (string as NSString).range(of: "**focus mode** • back")
        #expect(attributed.attribute(.discordMarkdownBlock, at: range1.location, effectiveRange: nil) as? String == "code")

        let range2 = (string as NSString).range(of: "<t:1750000000:r> :rocket:")
        #expect(attributed.attribute(.discordMarkdownBlock, at: range2.location, effectiveRange: nil) as? String == "code")

        // Also test single-line code block: ```inline code block```
        let singleLineSource = "```simple code```"
        let singleAttributed = ProfileInlineAttributedText.make(
            source: singleLineSource,
            font: font,
            color: .labelColor,
            emojiImages: [:],
            stylesLinks: false
        )
        #expect(singleAttributed.string == "simple code")
        #expect(singleAttributed.attribute(.discordMarkdownBlock, at: 0, effectiveRange: nil) as? String == "code")
    }

    @Test func `profile layout manager computes code block and inline code rects`() throws {
        let source = "Before code:\n```\nline 1\nline 2\n```\nAnd `inline code` test"
        let font = NSFont.systemFont(ofSize: 14)
        let attributed = ProfileInlineAttributedText.make(
            source: source,
            font: font,
            color: .labelColor,
            emojiImages: [:],
            stylesLinks: false
        )

        let textView = ProfileSelectableTextView()
        textView.frame = NSRect(x: 0, y: 0, width: 300, height: 500)
        textView.textContainer?.containerSize = NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude)
        textView.textStorage?.setAttributedString(attributed)

        let layoutManager = try #require(textView.layoutManager as? ProfileLayoutManager)
        let textContainer = try #require(textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)

        let blockRects = layoutManager.blockRects()
        #expect(!blockRects.isEmpty)
        let (codeBlockRect, isCode) = blockRects[0]
        #expect(isCode)
        #expect(codeBlockRect.width > 0)
        #expect(codeBlockRect.height > 0)

        let glyphRange = layoutManager.glyphRange(for: textContainer)
        let inlineRects = layoutManager.rects(of: .discordMarkdownInlineCode, forGlyphRange: glyphRange, padding: DiscordMarkdown.inlineCodePadding)
        #expect(!inlineRects.isEmpty)
        #expect(inlineRects[0].width > 0)
        #expect(inlineRects[0].height > 0)
    }
}
