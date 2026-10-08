import AppKit
import CoreText
import OSLog
import SakuraCordModels
import SwiftUI

@MainActor
extension NativeMemberListCanvasView {
    func drawItems(
        in range: Range<Int>,
        context: CGContext,
        skeletonStyle: SkeletonDrawingStyle?
    ) {
        for index in range {
            draw(
                item: items[index],
                at: index,
                context: context,
                skeletonStyle: skeletonStyle
            )
        }
    }

    private func draw(
        item: Item,
        at index: Int,
        context: CGContext,
        skeletonStyle: SkeletonDrawingStyle?
    ) {
        switch item {
        case .header(let section):
            if section.isLoadingSkeleton, let skeletonStyle {
                drawSkeletonHeader(
                    at: index,
                    context: context,
                    style: skeletonStyle
                )
                return
            }
            guard !section.title.isEmpty else { return }
            drawSectionHeader(section, at: index, context: context)
        case .placeholder:
            guard let skeletonStyle else { return }
            drawSkeletonMember(
                at: index,
                context: context,
                style: skeletonStyle
            )
        case .member(let member, _):
            drawMember(member, at: index, context: context)
        }
    }

    private func drawSectionHeader(
        _ section: Header,
        at index: Int,
        context: CGContext
    ) {
        let label = "\(section.title) — \(section.totalCount)"
        let font = NSFont.interfaceSystemFont(
            ofSize: InterfaceTypographyMetrics.interfaceTextSize,
            weight: .semibold
        )
        let isRoleSection = if case .role = section.id { true } else { false }
        let showsRoleIndicator = presentation.roleColorDisplay != .hidden && isRoleSection
        let color: NSColor = if showsRoleIndicator {
            SakuraCordAccentColor.nsColor(forRoleColorHex: section.colorHex)
        } else {
            .secondaryLabelColor
        }
        let line = Self.line(label, font: font, color: color)
        let labelY = origins[index] + 12
        let labelX: CGFloat
        if showsRoleIndicator {
            let indicatorSize: CGFloat = InterfaceScale.metric(8)
            var lineAscent: CGFloat = 0
            CTLineGetTypographicBounds(line, &lineAscent, nil, nil)
            let glyphBounds = CTLineGetBoundsWithOptions(
                line,
                [.useGlyphPathBounds]
            )
            let labelMidY = labelY + lineAscent - glyphBounds.midY
            let indicatorRect = CGRect(
                x: NativeMemberListMetrics.horizontalInset + InterfaceScale.metric(10),
                y: labelMidY - indicatorSize / 2,
                width: indicatorSize,
                height: indicatorSize
            )
            let indicator = NSBezierPath(ovalIn: indicatorRect)
            if SakuraCordAccentColor.usesAccentFallback(
                forRoleColorHex: section.colorHex
            ) {
                color.withAlphaComponent(0.14).setFill()
                indicator.fill()
                color.setStroke()
                indicator.lineWidth = 1.25
                indicator.stroke()
            } else {
                color.setFill()
                indicator.fill()
            }
            labelX = indicatorRect.maxX + 6
        } else {
            labelX = NativeMemberListMetrics.horizontalInset + 10
        }
        Self.draw(
            line: line,
            at: CGPoint(
                x: labelX,
                y: labelY
            ),
            context: context
        )
    }

    func skeletonDrawingStyle() -> SkeletonDrawingStyle {
        let reducesMotion = NSWorkspace.shared
            .accessibilityDisplayShouldReduceMotion
        return SkeletonDrawingStyle(
            phase: reducesMotion ? nil : SkeletonShimmerStyle.phase(at: Date()),
            fullOpacityGradient: reducesMotion
                ? nil : skeletonGradient(opacity: 1),
            secondaryOpacityGradient: reducesMotion
                ? nil : skeletonGradient(opacity: 0.7)
        )
    }

    private func skeletonGradient(opacity: CGFloat) -> CGGradient? {
        CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                NSColor.labelColor.withAlphaComponent(0).cgColor,
                NSColor.labelColor.withAlphaComponent(0.18 * opacity).cgColor,
                NSColor.labelColor.withAlphaComponent(0.92 * opacity).cgColor,
                NSColor.labelColor.withAlphaComponent(0.18 * opacity).cgColor,
                NSColor.labelColor.withAlphaComponent(0).cgColor,
            ] as CFArray,
            locations: [0, 0.25, 0.5, 0.75, 1]
        )
    }

    private func drawSkeletonHeader(
        at index: Int,
        context: CGContext,
        style: SkeletonDrawingStyle
    ) {
        drawSkeletonShape(
            in: CGRect(
                x: NativeMemberListMetrics.horizontalInset + InterfaceScale.metric(10),
                y: origins[index]
                    + (NativeMemberListMetrics.sectionHeaderHeight - InterfaceScale.metric(10)) / 2,
                width: InterfaceScale.metric(96),
                height: InterfaceScale.metric(10)
            ),
            radius: InterfaceScale.metric(5),
            opacity: 1,
            context: context,
            style: style
        )
    }

    private func drawSkeletonMember(
        at index: Int,
        context: CGContext,
        style: SkeletonDrawingStyle
    ) {
        let row = paintedRowRect(at: index)
        let contentX = row.minX + 4
        let container = CGRect(
            x: contentX,
            y: row.minY
                + (row.height - NativeMemberListMetrics.avatarContainerSize) / 2,
            width: NativeMemberListMetrics.avatarContainerSize,
            height: NativeMemberListMetrics.avatarContainerSize
        )
        let avatar = CGRect(
            x: container.midX - NativeMemberListMetrics.avatarSize / 2,
            y: container.midY - NativeMemberListMetrics.avatarSize / 2,
            width: NativeMemberListMetrics.avatarSize,
            height: NativeMemberListMetrics.avatarSize
        )
        let presence = CGRect(
            x: avatar.minX + NativeMemberListMetrics.avatarSize - InterfaceScale.metric(10),
            y: avatar.minY + NativeMemberListMetrics.avatarSize - InterfaceScale.metric(10),
            width: InterfaceScale.metric(11),
            height: InterfaceScale.metric(11)
        )
        drawSkeletonShape(
            in: avatar,
            radius: NativeMemberListMetrics.avatarSize / 2,
            opacity: 1,
            context: context,
            style: style
        )
        drawSkeletonShape(
            in: presence,
            radius: InterfaceScale.metric(5.5),
            opacity: 1,
            context: context,
            style: style
        )

        let textX = contentX
            + NativeMemberListMetrics.avatarContainerSize + 8
        drawSkeletonShape(
            in: CGRect(x: textX, y: row.minY + InterfaceScale.metric(6), width: InterfaceScale.metric(104), height: InterfaceScale.metric(10)),
            radius: InterfaceScale.metric(5),
            opacity: 1,
            context: context,
            style: style
        )
        drawSkeletonShape(
            in: CGRect(x: textX, y: row.minY + InterfaceScale.metric(25), width: InterfaceScale.metric(138), height: InterfaceScale.metric(8)),
            radius: InterfaceScale.metric(4),
            opacity: 0.7,
            context: context,
            style: style
        )

        context.saveGState()
        context.setStrokeColor(NSColor.controlBackgroundColor.cgColor)
        context.setLineWidth(2)
        context.strokeEllipse(in: presence.insetBy(dx: 1, dy: 1))
        context.restoreGState()
    }

    private func drawSkeletonShape(
        in rect: CGRect,
        radius: CGFloat,
        opacity: CGFloat,
        context: CGContext,
        style: SkeletonDrawingStyle
    ) {
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
        context.saveGState()
        context.addPath(path)
        context.setFillColor(
            NSColor.white.withAlphaComponent(0.09 * opacity).cgColor
        )
        context.fillPath()
        guard let phase = style.phase,
              let gradient = opacity == 1
                ? style.fullOpacityGradient
                : style.secondaryOpacityGradient
        else {
            context.restoreGState()
            return
        }
        context.addPath(path)
        context.clip()
        let width = max(rect.width, 1)
        let startX = rect.minX
            + width
                * (
                    SkeletonShimmerStyle.startingOffsetFraction
                        + SkeletonShimmerStyle.travelFraction * phase
                )
        let bandWidth = width * SkeletonShimmerStyle.bandWidthFraction
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: startX, y: rect.midY),
            end: CGPoint(x: startX + bandWidth, y: rect.midY),
            options: []
        )
        context.restoreGState()
    }

    func drawMember(_ member: Member, at index: Int, context: CGContext) {
        guard rowOverlayIndex != index else { return }
        let row = paintedRowRect(at: index)
        let isSelected = selectedMemberID == member.id
        if let nameplate = member.user.nameplate {
            context.saveGState()
            context.addPath(CGPath(
                roundedRect: row,
                cornerWidth: NativeMemberListMetrics.rowCornerRadius,
                cornerHeight: NativeMemberListMetrics.rowCornerRadius,
                transform: nil
            ))
            context.clip()
            if let colors = NameplatePresentationPolicy.colors(for: nameplate.palette) {
                let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let color = Self.color(hex: isDark ? colors.dark : colors.light)
                let gradient = CGGradient(
                    colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [
                        color.withAlphaComponent(0.05).cgColor,
                        color.withAlphaComponent(0.20).cgColor,
                    ] as CFArray,
                    locations: [0, 1]
                )
                if let gradient {
                    context.drawLinearGradient(
                        gradient,
                        start: CGPoint(x: row.minX, y: row.midY),
                        end: CGPoint(x: row.maxX, y: row.midY),
                        options: []
                    )
                }
            }
            if let url = nameplate.staticURL, let image = images[url] {
                context.setAlpha(CGFloat(NameplatePresentationPolicy.opacity(isHovered: false)))
                Self.draw(image: image, in: row, context: context, fills: true)
                context.setAlpha(1)
            }
            context.restoreGState()
            requestImageIfNeeded(
                url: nameplate.staticURL,
                index: index,
                priority: .visible,
                maximumPixelDimension: 512
            )
            if isSelected {
                Self.fillRounded(row, color: .labelColor.withAlphaComponent(0.07), context: context)
            }
        } else if isSelected {
            Self.fillRounded(row, color: .labelColor.withAlphaComponent(0.07), context: context)
        }

        drawMemberForeground(member, at: index, context: context)
    }

    func drawMemberForeground(_ member: Member, at index: Int, context: CGContext) {
        let row = paintedRowRect(at: index)
        guard let prepared = preparedText[items[index].id] else { return }
        context.saveGState()
        context.clip(to: row)
        defer { context.restoreGState() }

        drawMemberAvatar(member, at: index, context: context)

        let textX = row.minX + 4 + NativeMemberListMetrics.avatarContainerSize + 8
        let nameY = prepared.activity == nil ? row.minY + 13 : row.minY + 5
        let botBadgeWidth = NativeAppBadgePresentation.width
        let tagPresentation = prepared.serverTag
        let roleColor = presentation.roleColorDisplay == .nextToNames
            ? MessageAuthorPresentation.topRoleColor(in: member.roles).map(Self.color(hex:)) : nil
        let geometry = memberNameGeometry(member, prepared: prepared, at: index)
        let nameX = geometry.nameX
        let nameLayout = geometry.layout
        if nameLayout.nameWidth > 0 {
            let visibleName = Self.truncatedLine(
                prepared.name,
                token: prepared.nameTruncationToken,
                maximumWidth: nameLayout.nameWidth
            )
            Self.draw(line: visibleName, at: CGPoint(x: nameX, y: nameY), context: context)
        }

        if let roleColor {
            context.setFillColor(roleColor.cgColor)
            context.fillEllipse(in: CGRect(x: textX, y: nameY + InterfaceScale.metric(5), width: InterfaceScale.metric(8), height: InterfaceScale.metric(8)))
        }
        if member.user.isBot, let accessory = nameLayout.accessoryFrames.first {
            if accessory.width >= botBadgeWidth {
                drawBotBadge(at: nameX + accessory.minX, nameY: nameY, context: context)
            }
        }
        if let tagPresentation, let frame = geometry.serverTagFrame {
            tagPresentation.draw(
                in: frame,
                badgeImage: tagPresentation.identity.badgeURL.flatMap { images[$0] },
                isHighlighted: hoveredServerTagID == items[index].id
                    || serverTagCardPresentation?.itemID == items[index].id,
                context: context
            )
            requestImageIfNeeded(
                url: tagPresentation.identity.badgeURL,
                index: index,
                priority: .visible,
                maximumPixelDimension: 32
            )
        }
        if let activity = prepared.activity,
           let truncationToken = prepared.activityTruncationToken
        {
            let maximumWidth = max(0, row.maxX - textX - 4 - InterfaceScale.metric(presentation.trailingAccessoryWidth))
            let visibleActivity = Self.truncatedLine(
                activity,
                token: truncationToken,
                maximumWidth: maximumWidth
            )
            let origin = CGPoint(x: textX, y: row.minY + InterfaceScale.metric(24))
            Self.draw(line: visibleActivity, at: origin, context: context)
            for region in NativeMemberActivityPresentation.emojiRegions(
                in: visibleActivity,
                origin: origin
            ) {
                guard let url = activityEmojiURL(for: region.reference) else { continue }
                if let image = images[url] {
                    Self.draw(
                        image: image,
                        aspectFitIn: region.frame,
                        context: context
                    )
                } else {
                    requestImageIfNeeded(
                        url: url,
                        index: index,
                        priority: .visible,
                        maximumPixelDimension: 64
                    )
                }
            }
        }
    }

    func drawMemberAvatar(
        _ member: Member,
        at index: Int,
        context: CGContext
    ) {
        let container = CGRect(
            x: NativeMemberListMetrics.horizontalInset + InterfaceScale.metric(4),
            y: origins[index] + 1
                + (NativeMemberListMetrics.paintedRowHeight
                    - NativeMemberListMetrics.avatarContainerSize) / 2,
            width: NativeMemberListMetrics.avatarContainerSize,
            height: NativeMemberListMetrics.avatarContainerSize
        )
        let avatar = CGRect(
            x: container.midX - NativeMemberListMetrics.avatarSize / 2,
            y: container.midY - NativeMemberListMetrics.avatarSize / 2,
            width: NativeMemberListMetrics.avatarSize,
            height: NativeMemberListMetrics.avatarSize
        )
        let opacity = presentation.opacity(for: member)
        let status = presentation.status(for: member)
        let isMobile = member.showsMobileIndicator
        let presenceIndicatorRect = AvatarPresencePresentation.indicatorRect(
            avatarRect: avatar,
            indicatorSize: NativeMemberListMetrics.presenceIndicatorSize,
            isMobile: isMobile
        )
        context.saveGState()
        context.setAlpha(opacity)
        if status != nil {
            context.addRect(context.boundingBoxOfClipPath)
            context.addPath(AvatarPresencePresentation.cutoutPath(
                avatarRect: avatar,
                indicatorSize: NativeMemberListMetrics.presenceIndicatorSize,
                isMobile: isMobile
            ).cgPath)
            context.clip(using: .evenOdd)
        }

        let avatarURL = member.guildAvatarURL ?? member.user.avatarURL
        context.saveGState()
        context.addEllipse(in: avatar)
        context.clip()
        if let avatarURL, let image = images[avatarURL] {
            Self.draw(
                image: image,
                in: avatar,
                context: context,
                fills: true
            )
        } else {
            drawAvatarFallback(
                name: member.user.displayName,
                in: avatar,
                context: context
            )
        }
        context.restoreGState()
        requestImageIfNeeded(
            url: avatarURL,
            index: index,
            priority: .visible,
            maximumPixelDimension: 96
        )

        if let decorationURL = member.user.avatarDecorationURL {
            if let decoration = images[decorationURL] {
                let decorationSize = NativeMemberListMetrics.avatarSize * 1.22
                Self.draw(
                    image: decoration,
                    aspectFitIn: CGRect(
                        x: container.midX - decorationSize / 2,
                        y: container.midY - decorationSize / 2,
                        width: decorationSize,
                        height: decorationSize
                    ),
                    context: context
                )
            }
            requestImageIfNeeded(
                url: decorationURL,
                index: index,
                priority: .visible,
                maximumPixelDimension: 96
            )
        }

        context.restoreGState()

        if let status {
            drawPresenceIndicator(
                status,
                isMobile: isMobile,
                in: presenceIndicatorRect,
                context: context
            )
        }
    }

    func drawAvatarFallback(
        name: String,
        in rect: CGRect,
        context: CGContext
    ) {
        let accent = SakuraCordAccentColor.nsColor
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                accent.blended(withFraction: 0.18, of: .white)?.cgColor
                    ?? accent.cgColor,
                accent.blended(withFraction: 0.16, of: .black)?.cgColor
                    ?? accent.cgColor,
            ] as CFArray,
            locations: [0, 1]
        )
        if let gradient {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.minX, y: rect.minY),
                end: CGPoint(x: rect.maxX, y: rect.maxY),
                options: []
            )
        } else {
            context.setFillColor(accent.cgColor)
            context.fill(rect)
        }
        guard let initial = name.first.map({ String($0).uppercased() }) else {
            return
        }
        let line = Self.line(
            initial,
            font: .systemFont(
                ofSize: NativeMemberListMetrics.avatarSize * 0.42,
                weight: .semibold
            ),
            color: .white
        )
        let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        var ascent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, nil, nil)
        // draw(line:) adds ascent and flips Core Text's baseline coordinates.
        Self.draw(
            line: line,
            at: CGPoint(
                x: rect.midX - bounds.width / 2 - bounds.minX,
                y: rect.midY + bounds.midY - ascent
            ),
            context: context
        )
    }

    func drawPresenceIndicator(
        _ status: PresenceStatus,
        isMobile: Bool,
        in rect: CGRect,
        context: CGContext
    ) {
        context.saveGState()
        context.addPath(
            PresenceIndicatorPresentation.outline(isMobile: isMobile, in: rect).cgPath
        )
        context.clip()
        context.addPath(
            PresenceIndicatorPresentation.path(for: status, isMobile: isMobile, in: rect).cgPath
        )
        context.setFillColor(
            Self.color(
                hex: PresenceIndicatorPresentation.colorHex(for: status)
            ).cgColor
        )
        context.drawPath(using: .eoFill)
        context.restoreGState()
    }

    func drawBotBadge(at badgeX: CGFloat, nameY: CGFloat, context: CGContext) {
        let badge = CGRect(
            x: badgeX, y: nameY + InterfaceScale.metric(8) - ServerTagAppearance.height / 2,
            width: NativeAppBadgePresentation.width, height: ServerTagAppearance.height
        )
        NativeAppBadgePresentation.draw(in: badge, color: .systemIndigo, context: context)
    }

}
