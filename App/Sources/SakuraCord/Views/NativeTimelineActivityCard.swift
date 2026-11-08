import AppKit
import SakuraCordModels

/// Discord's Activity card for an Activity invite or launch message. An
/// invite shows the 16:9 cover, the Activity's name, its icon beside what the
/// card offers and where, and one full-width action; a launch message is a
/// coverless "Game Invitation" with the icon, the name, who is playing or that
/// the game ended, and Join or Play. Plain cards keep Discord's tinted
/// surface; in a bubble the card joins the bubble like other integrated cards.
struct ActivityCardGeometry {
    static var maximumWidth: CGFloat { InterfaceScale.metric(343) }

    let frame: CGRect
    let bannerFrame: CGRect
    let iconFrame: CGRect
    let symbolFrame: CGRect?
    let buttonFrame: CGRect
    let labels: [NativeTimelineInviteLayout.Label]
    let playerAvatars: [(frame: CGRect, url: URL?)]

    init(content: NativeServerCardContent, activity: ServerInvite.Activity, reference: ServerInviteReference?,
         error: String?, origin: CGPoint, maximumWidth: CGFloat, source: AppModel?, integratesWithBubble: Bool) {
        // In a bubble the card spans the bubble, as other integrated cards do.
        let width = integratesWithBubble ? maximumWidth : min(Self.maximumWidth, maximumWidth)
        let inset = integratesWithBubble ? 0 : InterfaceScale.metric(12)
        let gap = InterfaceScale.metric(12)
        let inner = max(1, width - inset * 2)
        let instanceID = content.activityInstanceID
        let showsCover = instanceID == nil && activity.coverURL != nil
        bannerFrame = CGRect(x: origin.x, y: origin.y, width: width, height: showsCover ? (width * 9 / 16).rounded() : 0)
        var cursor = bannerFrame.maxY + (!showsCover && integratesWithBubble ? 0 : gap)
        var labels: [NativeTimelineInviteLayout.Label] = []
        labels.append(.init(text: instanceID == nil ? activity.name : "Game Invitation",
                            frame: CGRect(x: origin.x + inset, y: cursor, width: inner, height: InterfaceScale.metric(18)),
                            bold: true, secondary: true, lineHeight: 18))
        cursor += InterfaceScale.metric(18) + gap
        // Discord drops the icon once the card is too narrow for it.
        let showsIcon = width > InterfaceScale.metric(270)
        let iconSize = InterfaceScale.metric(integratesWithBubble ? 48 : 64)
        iconFrame = CGRect(x: origin.x + inset, y: cursor, width: showsIcon ? iconSize : 0, height: showsIcon ? iconSize : 0)
        let textX = showsIcon ? iconFrame.maxX + gap : origin.x + inset
        let textWidth = max(1, origin.x + inset + inner - textX)
        let title = instanceID == nil ? "Activity Invite" : activity.name
        let players = source?.activityPlayers(reference: reference, instanceID: instanceID) ?? []
        let hasEnded = instanceID.map { source?.embeddedActivities.instances[$0] == nil } ?? false
        let place = hasEnded ? "Game ended. Start a new one?"
            : activity.channelName.map { content.guildName.isEmpty ? $0 : "\($0) in \(content.guildName)" }
        // Discord centres the title and its lines beside the icon.
        let textHeight = InterfaceScale.metric(20 + (place == nil ? 0 : 18) + (players.isEmpty ? 0 : 18))
        var textCursor = cursor + max(0, (iconFrame.height - textHeight) / 2)
        labels.append(.init(text: title, frame: CGRect(x: textX, y: textCursor, width: textWidth, height: InterfaceScale.metric(20)),
                            size: 16, bold: true))
        textCursor += InterfaceScale.metric(20)
        if let place {
            // Only a voice channel line carries the speaker symbol.
            let symbolWidth = hasEnded ? 0 : InterfaceScale.metric(18)
            symbolFrame = hasEnded ? nil : CGRect(x: textX, y: textCursor + InterfaceScale.metric(2),
                                                  width: InterfaceScale.metric(14), height: InterfaceScale.metric(14))
            labels.append(.init(text: place, frame: CGRect(x: textX + symbolWidth, y: textCursor,
                                                           width: textWidth - symbolWidth, height: InterfaceScale.metric(18)),
                                size: 12, secondary: true, lineHeight: 18))
            textCursor += InterfaceScale.metric(18)
        } else {
            symbolFrame = nil
        }
        let avatarSize = InterfaceScale.metric(16), overlap = InterfaceScale.metric(4)
        playerAvatars = players.prefix(3).enumerated().map { index, userID in
            (CGRect(x: textX + CGFloat(index) * (avatarSize - overlap), y: textCursor + InterfaceScale.metric(1),
                    width: avatarSize, height: avatarSize), source?.activityPlayerAvatarURL(userID))
        }
        if let last = playerAvatars.last {
            let textX = last.frame.maxX + InterfaceScale.metric(4)
            labels.append(.init(text: "\(players.count) Playing", frame: CGRect(x: textX, y: textCursor,
                                                                              width: max(1, origin.x + inset + inner - textX),
                                                                              height: InterfaceScale.metric(18)),
                                size: 12, secondary: true, lineHeight: 18))
            textCursor += InterfaceScale.metric(18)
        }
        cursor = max(textCursor, iconFrame.maxY) + gap
        // Why the invite can't be used, such as an expired link.
        if let error {
            let height = NativeTimelineInviteLayout.height(error, width: inner, size: 12, lineHeight: 16)
            labels.append(.init(text: error, frame: CGRect(x: origin.x + inset, y: cursor, width: inner, height: height),
                                size: 12, secondary: true, lineHeight: 16))
            cursor += height + gap
        }
        buttonFrame = CGRect(x: origin.x + inset, y: cursor, width: inner,
                             height: InterfaceScale.metric(integratesWithBubble ? 32 : 40))
        cursor = buttonFrame.maxY + inset
        frame = CGRect(x: origin.x, y: origin.y, width: width, height: cursor - origin.y)
        self.labels = labels
    }
}

extension NativeTimelineInviteLayout {
    /// The Activity an invite targets or a launch message announces, if this card is one.
    static func activityContent(reference: ServerInviteReference?, preview: NativeServerCardContent?,
                                source: AppModel?) -> NativeServerCardContent? {
        let content = preview ?? reference.flatMap { source?.inviteEntry(for: $0)?.invite }.map(NativeServerCardContent.init)
        return content?.activity == nil ? nil : content
    }

    init(activityCard content: NativeServerCardContent, activity: ServerInvite.Activity, reference: ServerInviteReference?,
         index: Int, origin: CGPoint, maximumWidth: CGFloat, source: AppModel?, integratesWithBubble: Bool) {
        var content = content, activity = activity
        // The card shows the shelf's cover once the shelf has loaded.
        activity.coverURL = source?.embeddedActivities.application(activity.applicationID)?.coverURL ?? activity.coverURL
        content.activity = activity
        let entry = reference.flatMap { source?.inviteEntry(for: $0) }
        let error = entry?.error ?? entry?.invite.flatMap {
            source?.presentationGuild($0.guildID) == nil ? $0.unsupportedJoinReason : nil
        }
        let card = ActivityCardGeometry(content: content, activity: activity, reference: reference, error: error,
                                        origin: origin, maximumWidth: maximumWidth, source: source,
                                        integratesWithBubble: integratesWithBubble)
        self.reference = reference
        self.content = content
        self.integratesWithBubble = integratesWithBubble
        componentID = "activity-card:\(index):\(reference?.code ?? content.activityInstanceID ?? "")"
        invite = entry?.invite
        // Tinted from the cover, or a launch message's icon, never the server's brand.
        gradientColor = entry?.adaptiveColor
            ?? (content.activityInstanceID == nil ? nil : content.iconURL.flatMap(ProfileAvatarPaletteLoader.shared.cached)?.first)
        self.error = error
        (isUnavailable, isExpanded, hasCollapsedContent) = (false, true, false)
        (frame, bannerFrame, iconFrame, symbolFrame, buttonFrame) = (
            card.frame, card.bannerFrame, card.iconFrame, card.symbolFrame, card.buttonFrame
        )
        (labels, countDots, traits, playerAvatars, contentBottom) = (card.labels, [], [], card.playerAvatars, card.frame.maxY)
        (inviterAvatarFrame, detailsFrame) = (nil, nil)
        (buttonTitle, isDisabled) = Self.action(for: invite, entry: entry, content: content, source: source)
    }
}

extension NativeTimelineRowPainter {
    static func activityCard(_ card: NativeTimelineInviteLayout, bubbleRegion: NativeTimelineBubbleRegion?,
                             isHovered: Bool, pressProgress: CGFloat) {
        guard let content = card.content, let activity = content.activity else { return }
        let bubble = card.integratesWithBubble ? bubbleRegion : nil
        let foreground = bubble.map { _ in NativeTimelineBubbleDrawing.foregroundColor(for: bubble) } ?? .white
        let secondary = bubble.map { _ in NativeTimelineBubbleDrawing.secondaryForegroundColor(for: bubble) }
            ?? NSColor.white.withAlphaComponent(0.7)
        let radius = NativeTimelineInviteLayout.cornerRadius
        let shape = bubble.map(NativeTimelineBubbleDrawing.bodyPath)
            ?? NSBezierPath(roundedRect: card.frame, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        // In a bubble the card sits on the bubble itself; its cover tile sets it apart.
        if bubble == nil { activityGradient(card.gradientColor ?? 0x3D3D3C, in: card.frame) }
        if card.bannerFrame.height > 0, let url = activity.coverURL {
            NSGraphicsContext.saveGraphicsState()
            if bubble != nil {
                // Inside a bubble the cover is its own tile, concentric with the bubble.
                NSBezierPath(concentricRoundedRect: card.bannerFrame, cornerRadius: InterfaceScale.metric(14)).addClip()
            }
            NSColor.black.withAlphaComponent(0.2).setFill()
            card.bannerFrame.fill()
            if let image = mediaImage(for: .media(url, maximumPixelDimension: 640)) {
                drawImage(image, in: card.bannerFrame, cornerRadius: 0, fillsFrame: true)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        if card.iconFrame.width > 0 {
            let iconShape = NSBezierPath(concentricRoundedRect: card.iconFrame, cornerRadius: InterfaceScale.metric(14))
            NSColor.black.withAlphaComponent(0.64).setFill()
            iconShape.fill()
            if let url = content.iconURL, let image = mediaImage(for: .media(url, maximumPixelDimension: 128)) {
                NSGraphicsContext.saveGraphicsState()
                iconShape.addClip()
                drawImage(image, in: card.iconFrame, cornerRadius: 0, fillsFrame: true)
                NSGraphicsContext.restoreGraphicsState()
            }
            NSColor.black.withAlphaComponent(0.2).setStroke()
            iconShape.lineWidth = 1
            iconShape.stroke()
        }
        if let symbolFrame = card.symbolFrame {
            systemSymbol("speaker.wave.2.fill", in: symbolFrame, color: secondary, inset: 0)
        }
        for label in card.labels {
            attributedText(label.attributedText(color: label.secondary ? secondary : foreground), in: label.frame, model: nil)
        }
        for avatar in card.playerAvatars.reversed() {
            // Each face is cut out of the card so the stack reads as separate circles.
            let ring = NSBezierPath(ovalIn: avatar.frame.insetBy(dx: -1.5, dy: -1.5))
            (bubble.map(NativeTimelineBubbleDrawing.fillColor) ?? NSColor.black.withAlphaComponent(0.6)).setFill()
            ring.fill()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: avatar.frame).addClip()
            NSColor.gray.setFill()
            avatar.frame.fill()
            if let url = avatar.url, let image = mediaImage(for: .media(url, maximumPixelDimension: 32)) {
                drawImage(image, in: avatar.frame, cornerRadius: 0, fillsFrame: true)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        if card.buttonFrame.height > 0 {
            // Discord's white button with a dark label reads on any cover tint and bubble colour.
            sakuraCordButton(
                title: card.buttonTitle, frame: card.buttonFrame, isHovered: isHovered && !card.isDisabled,
                pressProgress: card.isDisabled ? 0 : pressProgress, colors: [.white], foreground: .black,
                isEnabled: !card.isDisabled
            )
        }
        NSGraphicsContext.restoreGraphicsState()
        guard bubble == nil else { return }
        NSColor.white.withAlphaComponent(0.08).setStroke()
        let border = NSBezierPath(roundedRect: card.frame.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
        border.lineWidth = 1
        border.stroke()
    }

    /// Discord tints the card with a 45° gradient from the cover's colour,
    /// darkened so white text stays legible on any art.
    private static func activityGradient(_ hex: UInt32, in frame: CGRect) {
        let base = NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        func scaled(_ factor: CGFloat) -> NSColor {
            NSColor(srgbRed: base.redComponent * factor, green: base.greenComponent * factor,
                    blue: base.blueComponent * factor, alpha: 1)
        }
        NSGradient(starting: scaled(0.27), ending: scaled(0.035))?.draw(in: frame, angle: -45)
    }
}
