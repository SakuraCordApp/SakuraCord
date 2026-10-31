import AppKit
import SakuraCordModels

extension User {
    static let autoMod = User(id: UserID(rawValue: 0), username: "AutoMod", displayName: "AutoMod", isSystem: true)
}

extension NSAttributedString.Key {
    /// Text an AutoMod rule matched, highlighted like Discord does.
    static let autoModerationMatch = NSAttributedString.Key("SakuraCordAutoModerationMatch")
}

nonisolated enum AutoModAlertPresentation {
    /// What follows AutoMod's name: the alert's channel is a mention, so it
    /// opens like any other.
    static func headline(_ alert: AutoModerationAlert) -> String {
        let verb = alert.isFlagged ? "has flagged a message" : "has blocked a message"
        return alert.channelID.map { "\(verb) in <#\($0)>" } ?? verb
    }
}

/// The card under AutoMod's headline: the caught message under its sender,
/// the keyword and rule that matched, and the moderation actions. Its
/// corners share the poll card's geometry, so the avatar and the capsule
/// buttons sit concentric with them.
struct NativeTimelineAutoModAlertLayout {
    enum Action: String {
        case moderate = "automod.moderate"
        case jump = "automod.jump"

        var title: String {
            switch self {
            case .moderate: "Actions"
            case .jump: "Jump to Surrounding"
            }
        }
    }

    struct Header {
        let avatarFrame: CGRect
        let nameFrame: CGRect
        let name: NativeIdentityTextPresentation
    }

    struct Button {
        let action: Action
        let frame: CGRect
    }

    /// AutoMod's own avatar and name. The row's author frames are the sender's.
    let header: Header?
    let cardFrame: CGRect
    let avatarFrame: CGRect
    let authorFrame: CGRect
    let authorText: NativeIdentityTextPresentation
    let serverTag: NativeTimelineRowLayout.ServerTagRegion?
    /// The caught message, then the keyword and rule, as an unframed embed
    /// region so links, spoilers, emoji, selection and accessibility work
    /// as they do in any embed's text.
    let text: NativeTimelineRowLayout.EmbedRegion
    let buttons: [Button]

    static var cornerRadius: CGFloat { NativeTimelinePollLayout.cornerRadius }

    init(alert: AutoModerationAlert, message: Message, sender: User, header: Header?,
         origin: CGPoint, width: CGFloat, source: AppModel?, authorFont: NSFont) {
        self.header = header
        let cardWidth = min(width, DiscordRichMessageMetrics.maximumWidth)
        let inset = NativeTimelinePollLayout.inset
        let diameter = NativeTimelineComponentButtonMetrics.height
        avatarFrame = CGRect(x: origin.x + inset, y: origin.y + inset, width: diameter, height: diameter)
        let textX = avatarFrame.maxX + InterfaceScale.metric(12)
        let textWidth = max(1, origin.x + cardWidth - inset - textX)

        let font = ProfileNameFontLoader.shared.resolvedFont(for: sender, fallback: authorFont)
        let tag = sender.primaryGuild.flatMap { NativeServerTagPresentation(identity: $0) }?
            .fitting(maximumWidth: textWidth - InterfaceScale.metric(39))
        let name = NativeIdentityTextPresentation(
            sender.displayName, font: font,
            maximumWidth: textWidth - (tag.map { $0.width + InterfaceScale.metric(7) } ?? 0)
        )
        let nameHeight = ceil(max(font.ascender - font.descender, tag == nil ? 0 : ServerTagAppearance.height))
        let nameFrame = CGRect(x: textX, y: avatarFrame.minY, width: name.width, height: nameHeight)
        authorText = name
        authorFrame = nameFrame
        serverTag = tag.map {
            let baselineY = nameFrame.minY + name.baselineOffset(inHeight: nameHeight)
            return .init(frame: CGRect(
                x: nameFrame.maxX + InterfaceScale.metric(7),
                y: baselineY - $0.textBaselineOffset - InterfaceScale.metric(1),
                width: $0.width, height: ServerTagAppearance.height
            ), presentation: $0)
        }

        var cursor = authorFrame.maxY + InterfaceScale.metric(2)
        var regions: [NativeTimelineRowLayout.EmbedRegion.TextRegion] = []
        let embed = message.embeds.first { $0.type == "auto_moderation_message" }
        let content = embed.flatMap { Self.content(alert, embed: $0, message: message, source: source) }
        for box in [content, Self.details(alert)].compactMap({ $0 }) {
            if !regions.isEmpty { cursor += InterfaceScale.metric(4) }
            let height = NativeTimelineRowLayout.measuredTextHeight(
                box.framesetter, value: box.value, length: box.value.length, width: textWidth
            )
            regions.append(.init(frame: CGRect(x: textX, y: cursor, width: textWidth, height: height),
                                 text: box, isSelectable: true))
            cursor += height
        }
        let textTop = authorFrame.maxY
        text = .init(
            embedID: embed?.id ?? "", kind: .unframed,
            frame: CGRect(x: textX, y: textTop, width: textWidth, height: max(0, cursor - textTop)),
            textRegions: regions, imageRegions: [], mediaFrame: nil, mediaURL: nil, mediaPreviewURL: nil,
            mediaPlaceholder: nil, mediaIsVideo: false, mediaAutoplaysInline: false,
            mediaPosterFillsFrame: false, accentColor: nil, drawsTopSeparator: false
        )

        // Buttons wrap to another row when a narrow timeline can't fit both.
        let spacing = InterfaceScale.metric(8)
        var buttonOrigin = CGPoint(x: origin.x + inset, y: max(cursor, avatarFrame.maxY) + InterfaceScale.metric(12))
        buttons = ([.moderate] + (alert.channelID == nil ? [] : [.jump])).map { (action: Action) in
            let width = min(cardWidth - inset * 2, NativeTimelineRowLayout.measuredTextWidth(
                action.title, font: NativeTimelineComponentButtonMetrics.font
            ) + NativeTimelineComponentButtonMetrics.horizontalPadding * 2)
            if buttonOrigin.x > origin.x + inset, buttonOrigin.x + width > origin.x + cardWidth - inset {
                buttonOrigin = CGPoint(x: origin.x + inset, y: buttonOrigin.y + diameter + spacing)
            }
            defer { buttonOrigin.x += width + spacing }
            return Button(action: action, frame: CGRect(origin: buttonOrigin, size: CGSize(width: width, height: diameter)))
        }
        cardFrame = CGRect(x: origin.x, y: origin.y, width: cardWidth, height: buttonOrigin.y + diameter + inset - origin.y)
    }

    /// Measured heights trim Core Text's fractional leading, which would
    /// drop the last line; this matches the headroom message content gets.
    private static let drawingHeadroom: CGFloat = 2

    func button(at point: CGPoint) -> Button? {
        buttons.first { $0.frame.contains(point) }
    }

    /// The caught message renders as the alert embed's description, at
    /// message size, with each match marked.
    private static func content(
        _ alert: AutoModerationAlert, embed: MessageEmbed, message: Message, source: AppModel?
    ) -> NativeTimelineAttributedTextBox? {
        guard !alert.content.isEmpty else { return nil }
        let rendered = NativeTimelineEmbedLayout.resolvedTextBox(
            prepared: RichMessageAttributedText.prepare(source: alert.content), scope: "automod",
            emojiSize: 22, embed: embed, message: message, source: source
        ).value
        let value = NSMutableAttributedString(attributedString: rendered)
        if let match = alert.matchedContent {
            let text = value.string as NSString
            var range = text.range(of: match, options: .caseInsensitive)
            while range.location != NSNotFound {
                value.addAttribute(.autoModerationMatch, value: true, range: range)
                let next = NSMaxRange(range)
                range = text.range(of: match, options: .caseInsensitive,
                                   range: NSRange(location: next, length: text.length - next))
            }
        }
        return NativeTimelineAttributedTextBox(value, layoutHeightAdjustment: drawingHeadroom)
    }

    /// Keywords are often patterns, so they show verbatim, never as markdown.
    private static func details(_ alert: AutoModerationAlert) -> NativeTimelineAttributedTextBox? {
        let parts = [alert.keyword.map { "Keyword: \($0)" }, alert.ruleName.map { "Rule: \($0)" }].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        return NativeTimelineAttributedTextBox(NSAttributedString(
            string: parts.joined(separator: "\n"),
            attributes: [
                .font: NSFont.interfaceSystemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
        ), layoutHeightAdjustment: drawingHeadroom)
    }
}

extension NativeTimelineRowPainter {
    /// Discord's search-highlight yellow at 30%, behind text a rule matched.
    static let autoModerationMatchColor = NSColor(srgbRed: 253 / 255, green: 184 / 255, blue: 51 / 255, alpha: 0.3)

    /// Drawn before the row's identity, which paints the sender's avatar and
    /// name inside the card.
    static func drawAutoModAlert(_ input: NativeTimelineMessageDrawInput) {
        guard let alert = input.layout.autoModAlert else { return }
        if let header = alert.header {
            NSColor.sakuraCordAccentColor.setFill()
            NSBezierPath(ovalIn: header.avatarFrame).fill()
            systemSymbol("checkmark.shield.fill", in: header.avatarFrame, color: .white,
                         inset: header.avatarFrame.width * 0.25, weight: .semibold)
            if let context = NSGraphicsContext.current?.cgContext {
                header.name.draw(in: header.nameFrame, color: .sakuraCordAccentColor, context: context)
            }
        }
        pollSurface(in: alert.cardFrame, cornerRadius: NativeTimelineAutoModAlertLayout.cornerRadius)
        for button in alert.buttons {
            let target = NativeTimelineComponentButtonTarget(messageID: input.row.message.id, componentID: button.action.rawValue)
            sakuraCordButton(
                title: button.action.title, frame: button.frame,
                isHovered: input.hoveredComponentButton == target,
                pressProgress: input.pressedComponentButton == target ? input.componentButtonPressProgress : 0,
                colors: [.controlColor], foreground: .labelColor
            )
        }
    }
}

extension NativeTimelineCanvasView {
    @discardableResult
    func activateAutoModAlertAction(
        _ action: NativeTimelineAutoModAlertLayout.Action, message: Message, anchor: CGRect
    ) -> Bool {
        guard let model, let alert = message.autoModerationAlert else { return false }
        let guildID = model.messagePresentationGuildID(for: message)
        switch action {
        case .moderate:
            UserContextMenu.make(
                for: message.author,
                context: .init(guildID: guildID, channelID: message.channelID, isLocalIdentity: false),
                model: model
            ).popUp(positioning: nil, at: NSPoint(x: anchor.minX, y: anchor.maxY + InterfaceScale.metric(4)), in: self)
        case .jump:
            // The alert was posted as the message was caught, so its ID
            // opens the channel at that moment.
            guard let channelID = alert.channelID else { return false }
            model.navigate(to: guildID, channelID: channelID, messageID: message.id, nearest: true)
        }
        return true
    }

    func appendAutoModAlertAccessibility(
        message: Message, to children: inout [Any], layout: NativeTimelineRowLayout,
        rowIndex: Int, parent: NSAccessibilityElement
    ) {
        guard let alert = layout.autoModAlert else { return }
        let group = accessibilityElement(
            role: .group,
            label: "AutoMod alert actions",
            frame: accessibilityChildFrame(alert.cardFrame, rowIndex: rowIndex),
            parent: parent
        )
        group.setAccessibilityChildren(alert.buttons.map { button in
            accessibilityElement(
                role: .button, label: button.action.title,
                frame: accessibilityChildFrame(button.frame, rowIndex: rowIndex), parent: group
            ) { [weak self] in
                guard let self else { return false }
                return activateAutoModAlertAction(
                    button.action, message: message, anchor: accessibilityChildFrame(button.frame, rowIndex: rowIndex)
                )
            }
        })
        children.append(group)
    }
}
