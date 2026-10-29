import Foundation
import SakuraCordModels

extension MockMessageFixtureBuilder {
    func messageShowcase() -> [Message] {
        showcaseText() + showcaseMedia() + showcaseEmbeds()
            + showcaseComponents() + showcaseReferencesAndStates() + showcasePolls()
            + showcaseSystemMessages() + showcaseBubbleGroups() + showcaseThreadCards()
    }

    var showcaseThread: MessageThreadSummary {
        MessageThreadSummary(
            id: ChannelID(rawValue: 902), guildID: auroraID, parentID: ChannelID(rawValue: 216),
            name: "Showcase thread", messageCount: 2, memberCount: 2, lastMessageID: MessageID(rawValue: 609_002)
        )
    }

    /// Thread cards in each state: busy, empty, archived, locked and long-named,
    /// under a message and as a thread-starter system message.
    func showcaseThreadCards() -> [Message] {
        func thread(
            _ number: UInt64, _ name: String, messages: Int, archived: Bool = false, locked: Bool = false
        ) -> MessageThreadSummary {
            MessageThreadSummary(
                id: ChannelID(rawValue: 1_400_000_000_000_000_000 + number), guildID: auroraID,
                parentID: ChannelID(rawValue: 216), name: name, messageCount: messages,
                isArchived: archived, isLocked: locked, createdAt: now.addingTimeInterval(-13 * 3_600)
            )
        }
        let long = "An extremely long thread name that cannot possibly fit on one line of the timeline card"
        return [
            showcaseMessage(800, content: "# Thread cards"),
            showcaseMessage(801, content: "A busy thread.") { $0.thread = thread(1, "Release checklist for side chats", messages: 133) },
            showcaseMessage(802, author: nova, content: "A thread nobody has answered yet.") { $0.thread = thread(2, "Empty thread", messages: 0) },
            showcaseMessage(803, content: "An archived thread.") { $0.thread = thread(3, "Q3 planning notes", messages: 48, archived: true) },
            showcaseMessage(804, author: nova, content: "A locked thread.") { $0.thread = thread(4, "Announcements discussion", messages: 12, locked: true) },
            showcaseMessage(805, content: "A thread with a very long name.") { $0.thread = thread(5, long, messages: 2) },
            showcaseMessage(806, author: nova) {
                $0.type = .threadCreated
                $0.content = long
                $0.thread = thread(6, long, messages: 1)
            },
            showcaseMessage(807, author: nova) {
                $0.type = .threadCreated
                $0.content = "Empty thread"
                $0.thread = thread(7, "Empty thread", messages: 0)
            },
        ]
    }

    func showcaseThreadMessages() -> [Message] {
        [maya, nova].enumerated().map { index, author in
            Message(id: MessageID(rawValue: UInt64(609_001 + index)), channelID: showcaseThread.id, author: author,
                    content: index == 0 ? "A reply inside the showcase thread." : "The thread uses the same message styles.",
                    timestamp: now.addingTimeInterval(Double(index - 2) * 60), guildID: auroraID)
        }
    }

    /// One stable ID namespace keeps paging, references, and local mutations
    /// independent of the other offline conversations.
    func showcaseMessage(
        _ number: UInt64,
        author: User? = nil,
        content: String = "",
        configure: (inout Message) -> Void = { _ in }
    ) -> Message {
        var message = Message(
            id: MessageID(rawValue: 600_000 + number),
            channelID: ChannelID(rawValue: 216),
            author: author ?? maya,
            content: content,
            timestamp: now.addingTimeInterval(-86_400 + Double(number) * 60),
            guildID: auroraID
        )
        configure(&message)
        return message
    }

    private func showcaseText() -> [Message] {
        let samples = [
            "# Text and typography",
            "A short incoming message.",
            "A short outgoing message.",
            String(repeating: "A longer message wraps naturally as you resize the window. ", count: 12),
            "First line.\nSecond line.\n\nA new paragraph after an empty line.",
            "**Bold**, *italic*, _also italic_, __underline__, ~~strikethrough~~, and ***bold italic***.",
            "__**Bold underline**__ · __*italic underline*__ · __***all three***__ · ~~__struck underline__~~",
            "Visible text, ||a concealed spoiler||, and ||**formatted spoiler**||.",
            "# Heading 1\n## Heading 2\n### Heading 3\n-# Small subtext beneath the headings.",
            "> A single-line block quote.\n\nBack to ordinary text.",
            ">>> A multiline quote.\nIts second line.\nIts third line.",
            "- Unordered item\n- Another item\n  - Nested item\n\n1. Ordered item\n2. Another ordered item",
            "Inline `code`, escaped \\*asterisks\\*, and a literal \\_underscore\\_.",
            "```\nA plain code block.\n    Indentation stays intact.\n```",
            "```swift\nstruct Greeting {\n    let message = \"Hello, SakuraCord 🌸\"\n}\n```",
            "```json\n{\n  \"theme\": \"sakura\",\n  \"bubbles\": true,\n  \"count\": 42\n}\n```",
            "```ansi\n\u{001B}[31mRed\u{001B}[0m \u{001B}[32mGreen\u{001B}[0m \u{001B}[1;34mBold blue\u{001B}[0m\n```",
            "[A labeled link](https://example.com) and https://example.com/a/longer/path?hello=world",
            "<https://example.com/no-preview> · contact@example.com · https://example.com/" + String(repeating: "long-path-", count: 18),
            "<@1> · <@!2> · <@&10> · <#211> · @everyone · @here",
            "<t:1700000000:t> · <t:1700000000:T> · <t:1700000000:d> · <t:1700000000:D>",
            "<t:1700000000:f> · <t:1700000000:F> · <t:1700000000:R>",
            "Inline Unicode 🌸, custom <:aurora_glow:900000000000000101>, and animated <a:animated_fixture:900000000000000104> emoji.",
            "🌸",
            "👩🏽‍💻 🏳️‍🌈 👨‍👩‍👧‍👦 ❤️‍🔥",
            "<:aurora_glow:900000000000000101>",
            "<a:animated_fixture:900000000000000104>",
            "日本語のメッセージ。한글 메시지. 中文消息。こんにちは 🌸",
            "مرحبا بالعالم — رسالة عربية\nשלום עולם — הודעה בעברית\nMixed direction: hello مرحبا 123.",
            "Combining marks: café / café · symbols ∑ → ∞ · full-width Ｓａｋｕｒａ",
        ]
        return samples.enumerated().map { index, content in
            showcaseMessage(UInt64(100 + index), author: index.isMultiple(of: 3) ? nova : maya, content: content) {
                if index == 19 {
                    $0.mentionedUsers = [nova, maya]
                    $0.mentionedRoleIDs = [RoleID(rawValue: 10)]
                    $0.mentionsEveryone = true
                }
            }
        }
    }

    private func showcaseReferencesAndStates() -> [Message] {
        let target = showcaseMessage(501, author: nova, content: "**Reply target** with `code`, a link, and 🌸.") {
            $0.isPinned = true
        }
        var result = [
            showcaseMessage(500, content: "# Replies, forwards, and message states"),
            target,
            showcaseMessage(502, content: "An incoming reply to the pinned message.") {
                $0.type = .reply
                $0.replyTo = target.id
                $0.replyPreview = MessageReplyPreview(message: target)
            },
            showcaseMessage(503, author: nova, content: "An outgoing reply that mentions its author.") {
                $0.type = .reply
                $0.replyTo = MessageID(rawValue: 600_502)
                $0.mentionedUsers = [maya]
            },
            showcaseMessage(504, content: "A reply whose original message is unavailable.") {
                $0.type = .reply
                $0.replyTo = MessageID(rawValue: 699_999)
                $0.replyPreview = MessageReplyPreview(
                    messageID: MessageID(rawValue: 699_999), author: theo, content: "A remembered message outside this history."
                )
            },
            showcaseMessage(505, author: nova, content: "") {
                $0.flags = [.forwarded]
                $0.messageReference = .init(type: .forward, messageID: MessageID(rawValue: 3101), channelID: ChannelID(rawValue: 301), guildID: nativeLabID)
                $0.forwardedSnapshot = .init(content: "A forwarded **message** with its original image.", timestamp: base, attachments: layoutAttachment.map { [$0] } ?? [])
            },
            showcaseMessage(506, content: "A message with an active thread.") { $0.thread = showcaseThread },
            showcaseMessage(507, content: "This message has been edited.") { $0.editedTimestamp = $0.timestamp.addingTimeInterval(15) },
            showcaseMessage(508, author: verifiedApp, content: "A webhook identity.") { $0.webhookID = "offline-showcase-webhook" },
            showcaseMessage(509, content: "An announcement crosspost.") { $0.flags = [.isCrosspost] },
            showcaseMessage(510, content: "Reactions with counts, reactors, custom emoji, and a burst reaction.") {
                $0.reactions = [
                    Reaction(emoji: "🌸", count: 12, didCurrentUserReact: true, reactors: [ReactionReactor(user: nova), ReactionReactor(user: maya)]),
                    Reaction(emoji: "<:aurora_glow:900000000000000101>", count: 3),
                    Reaction(emoji: "<a:animated_fixture:900000000000000104>", count: 2),
                    Reaction(emoji: "🔥", count: 99, didCurrentUserBurstReact: true),
                ]
            },
        ]
        let states: [OutboxState] = [.queued, .uploading, .sending, .awaitingReconciliation, .failed]
        result += states.enumerated().map { index, state in
            showcaseMessage(UInt64(520 + index), author: nova, content: "Outgoing message: \(state.rawValue).") {
                $0.outboxState = state
                $0.nonce = "showcase-outbox-\(state.rawValue)"
            }
        }
        let commandStates: [(String, MessageFlags)] = [
            ("A completed application command response.", []),
            ("A private application command response.", [.ephemeral]),
            ("An application command is thinking…", [.loading]),
            ("The application did not respond.", [.localInteractionFailure]),
        ]
        result += commandStates.enumerated().map { index, state in
            showcaseMessage(UInt64(530 + index), author: verifiedApp, content: state.0) {
                $0.type = .chatInputCommand
                $0.flags = state.1
                $0.applicationID = ApplicationID(rawValue: 900_000_000_000_000_101)
                $0.interactionMetadata = MessageInteractionMetadata(
                    id: "showcase-command-\(index)", type: 2, name: "inspect", user: nova, applicationID: "900000000000000101"
                )
            }
        }
        result += [
            showcaseMessage(540, author: verifiedApp, content: "A context-menu command response.") { $0.type = .contextMenuCommand },
            showcaseMessage(541, content: "The original message that started a thread.") { $0.type = .threadStarter },
            showcaseMessage(542, content: "A premium referral message.") { $0.type = .premiumReferral },
        ]
        return result
    }

    private func showcaseBubbleGroups() -> [Message] {
        [
            showcaseMessage(700, content: "# Bubble groups"),
            showcaseMessage(701, content: "An incoming group: ordinary text…"),
            showcaseMessage(702, content: "🌸 ✨"),
            showcaseMessage(703) { $0.stickers = demoSticker.map { [$0] } ?? [] },
            showcaseMessage(704, content: "…and its final message, with the avatar and tail."),
            showcaseMessage(705, author: nova, content: "The same group, outgoing:"),
            showcaseMessage(706, author: nova, content: "🌸 ✨"),
            showcaseMessage(707, author: nova) { $0.stickers = [lottieSticker] },
            showcaseMessage(708, author: nova, content: "Every message keeps its bubble."),
        ]
    }
}
