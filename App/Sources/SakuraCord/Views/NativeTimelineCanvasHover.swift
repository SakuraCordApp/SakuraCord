import AppKit
import Combine
import CoreText
import MessageRendering
import SakuraCordModels
import SwiftUI

extension NativeTimelineCanvasView {
    /// Redraws the rows a hover left and entered.
    func invalidateHoverRows(from old: Int?, to new: Int?) {
        for index in [old, new].compactMap(\.self) {
            setNeedsDisplay(rowFrame(at: index))
        }
    }

    /// Redraws the rows of the messages a hover left and entered.
    func invalidateHoverRows(from old: MessageID?, to new: MessageID?) {
        for messageID in [old, new].compactMap(\.self) {
            guard let index = items.firstIndex(where: { $0.messageID == messageID }) else { continue }
            setNeedsDisplay(rowFrame(at: index))
        }
    }

    func setHoveredRow(_ value: Int?) {
        guard hoveredRow != value else { return }
        let old = hoveredRow
        hoveredRow = value
        updateAvatarPlayback()
        invalidateHoverRows(from: old, to: value)
        if value == nil, actionCapsuleState?.isPresentationActive == true {
            return
        }
        reconcileActionCapsule()
    }

    func setHoveredSilentBadgeMessageID(_ value: MessageID?) {
        guard hoveredSilentBadgeMessageID != value else { return }
        hoveredSilentBadgeMessageID = value
        presentHoverLabel()
    }

    func setHoveredCommandPillMessageID(_ value: MessageID?) {
        guard hoveredCommandPillMessageID != value else { return }
        let old = hoveredCommandPillMessageID
        hoveredCommandPillMessageID = value
        for messageID in [old, value].compactMap({ $0 }) { invalidateVisibleMessageRow(messageID: messageID) }
    }

    func setHoveredCompactTimestampRow(_ value: Int?) {
        guard hoveredCompactTimestampRow != value else { return }
        let old = hoveredCompactTimestampRow
        hoveredCompactTimestampRow = value
        invalidateHoverRows(from: old, to: value)
    }

    func setHoveredAuthorMessageID(_ value: MessageID?) {
        guard hoveredAuthorMessageID != value else { return }
        let old = hoveredAuthorMessageID
        hoveredAuthorMessageID = value
        if let index = value.flatMap(visibleMessageRowIndex(for:)), scrollsAuthorGradient(at: index) {
            authorHoverTicker.start(on: self, frameRate: RoleGradientPaint.scrollFrameRate) { [weak self] in
                self?.stepAuthorHover()
            }
        } else {
            authorHoverTicker.stop()
        }
        updateAvatarPlayback()
        invalidateHoverRows(from: old, to: value)
    }

    /// A hovered gradient name scrolls, as Discord's does; solid names stay still.
    private func scrollsAuthorGradient(at index: Int) -> Bool {
        guard AppMotionPolicy.animatesUncategorized, model?.accessibilitySettings.roleColorDisplay == .inNames,
              case let .message(row, _, _) = items[index]
        else { return false }
        let author = model?.authorPresentation(for: row.message)
        return author?.user.isBot == false && NativeTimelineRowPainter.roleGradientColors(author) != nil
    }

    private func stepAuthorHover() {
        guard let index = hoveredAuthorMessageID.flatMap(visibleMessageRowIndex(for:)),
              let authorFrame = layouts[index].authorFrame
        else {
            authorHoverTicker.stop()
            return
        }
        // The glow reaches a few points past the name.
        setNeedsDisplay(authorFrame.offsetBy(dx: 0, dy: displayedRowOrigin(at: index)).insetBy(dx: -6, dy: -6))
    }

    func setHoveredMention(
        _ value: NativeTimelineMentionHover?
    ) {
        guard hoveredMention != value else { return }
        let oldIdentifier = hoveredMention?.itemIdentifier
        hoveredMention = value
        presentHoverLabel()
        for identifier
            in [oldIdentifier, value?.itemIdentifier].compactMap({ $0 })
        {
            guard let index = items.firstIndex(where: {
                $0.identifier == identifier
            }) else { continue }
            setNeedsDisplay(rowFrame(at: index))
        }
    }

    func setHoveredTextLink(
        _ value: NativeTimelineTextLinkHover?
    ) {
        guard hoveredTextLink != value else { return }
        let oldIdentifier = hoveredTextLink?.itemIdentifier
        hoveredTextLink = value
        for identifier
            in [oldIdentifier, value?.itemIdentifier].compactMap({ $0 })
        {
            guard let index = items.firstIndex(where: {
                $0.identifier == identifier
            }) else { continue }
            setNeedsDisplay(rowFrame(at: index))
        }
    }

    func setHoveredTextSpoiler(
        _ value: NativeTimelineTextSpoilerHover?
    ) {
        guard hoveredTextSpoiler != value else { return }
        let old = hoveredTextSpoiler
        hoveredTextSpoiler = value
        for identifier
            in [old?.itemIdentifier, value?.itemIdentifier].compactMap({ $0 })
        {
            guard let index = items.firstIndex(where: {
                $0.identifier == identifier
            }) else { continue }
            setNeedsDisplay(rowFrame(at: index))
        }
        let now = ProcessInfo.processInfo.systemUptime
        for (spoiler, isHovered) in [(old, false), (value, true)] {
            guard let spoiler else { continue }
            textSpoilerHoverFades[spoiler] = Self.hoverFade(
                from: textSpoilerHoverFades[spoiler]?.progress(at: now) ?? 0, isHovered: isHovered, at: now
            )
        }
        animateHoverFades()
    }

    /// How far each text spoiler in a row is hovered at this moment.
    func textSpoilerHoverProgress(
        in itemIdentifier: NativeMessageTimelineItem.Identifier
    ) -> [NativeTimelineTextSpoilerHover: CGFloat] {
        let now = ProcessInfo.processInfo.systemUptime
        return textSpoilerHoverFades.filter { $0.key.itemIdentifier == itemIdentifier }.mapValues { $0.progress(at: now) }
    }

    /// A hover easing in or out from wherever it is; Reduce Motion lands at once.
    private static func hoverFade(from current: CGFloat, isHovered: Bool, at now: TimeInterval) -> NativeTimelineHoverFade {
        let start = AppMotionPolicy.animatesUncategorized
            ? now : now - NativeTimelineComponentButtonVisualState.hoverAnimationDuration
        return .init(from: current, to: isHovered ? 1 : 0, start: start)
    }

    func setHoveredCodeBlock(
        _ value: NativeTimelineCodeBlockPointerTarget?
    ) {
        hoveredCodeBlock = value
        updateCodeCopyControl()
    }

    /// Shows the hovered code block's copy button with its hover and press,
    /// which follow the pointer within the block.
    func updateCodeCopyControl() {
        guard hoveredCodeBlock != nil || codeCopyControl != nil else { return }
        let control = codeCopyControl ?? {
            let created = NativeTimelineCodeCopyControl()
            // Under every overlay, as the row's own drawing is, so a spoiler
            // cover hides a concealed block's button.
            addSubview(created, positioned: .below, relativeTo: nil)
            codeCopyControl = created
            return created
        }()
        let isPressed = pressedCodeBlockCopyButton != nil && pressedCodeBlockCopyButton == hoveredCodeBlock
        control.update(
            target: hoveredCodeBlock,
            isHovered: isPressed || hoveredCodeBlock?.copyButtonFrame.contains(currentMouseLocationInCanvas()) == true,
            isPressed: isPressed
        )
    }

    func setHoveredComponentButton(
        _ value: NativeTimelineComponentButtonTarget?
    ) {
        guard hoveredComponentButton != value else { return }
        let old = hoveredComponentButton
        hoveredComponentButton = value
        for target in [old, value].compactMap({ $0 }) {
            invalidateComponentButton(target)
        }
        if let old { fadeFileCardHover(old, isHovered: false) }
        if let value { fadeFileCardHover(value, isHovered: true) }
    }

    /// Eases a file card part's hover in or out from wherever it is, so the
    /// pointer moving between parts or leaving the card never snaps.
    private func fadeFileCardHover(_ target: NativeTimelineComponentButtonTarget, isHovered: Bool) {
        guard target.componentID.hasPrefix("file:") else { return }
        let now = ProcessInfo.processInfo.systemUptime
        componentButtonHoverFades[target] = Self.hoverFade(
            from: componentButtonHoverFades[target]?.progress(at: now) ?? 0, isHovered: isHovered, at: now
        )
        animateHoverFades()
    }

    /// Crossfades a download's button from its full ring to its next step.
    func fadeFileCardFinish(_ target: NativeTimelineComponentButtonTarget) {
        guard AppMotionPolicy.animatesUncategorized else { return }
        fileCardFinishFades[target] = .init(from: 0, to: 1, start: ProcessInfo.processInfo.systemUptime)
        animateHoverFades()
    }

    private func animateHoverFades() {
        guard componentButtonHoverAnimationTask == nil else { return }
        var previous = ProcessInfo.processInfo.systemUptime
        componentButtonHoverAnimationTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                let now = ProcessInfo.processInfo.systemUptime
                // Work that holds the main thread, such as saving a finished
                // download, pauses the fades still running instead of skipping
                // them, each from the later of the stall's start and its own.
                // Under Reduce Motion every fade lands at once.
                let stallStart = previous + 1.0 / 30
                previous = now
                if now > stallStart, AppMotionPolicy.animatesUncategorized {
                    let resume = { (fade: NativeTimelineHoverFade) in
                        fade.isSettled(at: stallStart) ? fade : fade.delayed(by: now - max(stallStart, fade.start))
                    }
                    componentButtonHoverFades = componentButtonHoverFades.mapValues(resume)
                    textSpoilerHoverFades = textSpoilerHoverFades.mapValues(resume)
                    fileCardFinishFades = fileCardFinishFades.mapValues(resume)
                }
                redrawFadingHovers()
                // A faded-out part is forgotten; a hovered one holds.
                componentButtonHoverFades = componentButtonHoverFades.filter { !$0.value.isSettled(at: now) || $0.value.to > 0 }
                textSpoilerHoverFades = textSpoilerHoverFades.filter { !$0.value.isSettled(at: now) || $0.value.to > 0 }
                fileCardFinishFades = fileCardFinishFades.filter { !$0.value.isSettled(at: now) }
                guard componentButtonHoverFades.values.contains(where: { !$0.isSettled(at: now) })
                    || textSpoilerHoverFades.values.contains(where: { !$0.isSettled(at: now) })
                    || !fileCardFinishFades.isEmpty
                else {
                    componentButtonHoverAnimationTask = nil
                    return
                }
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }

    /// Redraws the file card parts and text spoilers still easing their
    /// hover, so dropping their fades leaves none on its last frame.
    func redrawFadingHovers() {
        for target in componentButtonHoverFades.keys { invalidateComponentButton(target) }
        for target in fileCardFinishFades.keys { invalidateComponentButton(target) }
        for identifier in Set(textSpoilerHoverFades.keys.map(\.itemIdentifier)) {
            guard let index = items.firstIndex(where: { $0.identifier == identifier }) else { continue }
            setNeedsDisplay(rowFrame(at: index))
        }
    }

    /// How far each download finishing in a message has crossfaded.
    func fileCardFinishProgress(in messageID: MessageID?) -> [NativeTimelineComponentButtonTarget: CGFloat] {
        let now = ProcessInfo.processInfo.systemUptime
        return fileCardFinishFades.filter { $0.key.messageID == messageID }.mapValues { $0.progress(at: now) }
    }

    /// The file card parts' hover in a message at this moment.
    func fileCardHoverProgress(in messageID: MessageID?) -> [NativeTimelineComponentButtonTarget: CGFloat] {
        let now = ProcessInfo.processInfo.systemUptime
        return componentButtonHoverFades.filter { $0.key.messageID == messageID }.mapValues { $0.progress(at: now) }
    }

    func setHoveredForwardedSourceMessageID(_ value: MessageID?) {
        guard hoveredForwardedSourceMessageID != value else { return }
        let old = hoveredForwardedSourceMessageID
        hoveredForwardedSourceMessageID = value
        invalidateHoverRows(from: old, to: value)
    }
    func setHoveredFooterAction(_ value: NativeTimelineFooterActionTarget?) {
        guard hoveredFooterAction != value else { return }
        let old = hoveredFooterAction
        hoveredFooterAction = value
        for target in [old, value].compactMap({ $0 }) {
            // A revealed run's header shares its first row's message ID.
            let header = NativeMessageTimelineItem.Identifier.suppressedMessages(target.messageID)
            guard let index = items.firstIndex(where: {
                target.kind == .suppressedToggle ? $0.identifier == header : $0.messageID == target.messageID
            }) else { continue }
            setNeedsDisplay(rowFrame(at: index))
        }
    }

    func animateComponentButtonPress(
        _ target: NativeTimelineComponentButtonTarget,
        to destination: CGFloat
    ) {
        let destination = min(max(destination, 0), 1)
        if visualPressedComponentButton != target {
            let old = visualPressedComponentButton
            componentButtonPressAnimationTask?.cancel()
            componentButtonPressProgress = 0
            visualPressedComponentButton = target
            if let old {
                invalidateComponentButton(old)
                positionComponentButtonEmoji(old)
            }
        }
        if abs(componentButtonPressProgress - destination) < 0.001 {
            componentButtonPressAnimationDestination = nil
            if destination == 0 {
                visualPressedComponentButton = nil
            }
            invalidateComponentButton(target)
            positionComponentButtonEmoji(target)
            return
        }
        guard componentButtonPressAnimationDestination != destination else {
            return
        }
        componentButtonPressAnimationTask?.cancel()
        componentButtonPressAnimationDestination = destination
        let start = componentButtonPressProgress
        let startTime = ProcessInfo.processInfo.systemUptime
        componentButtonPressAnimationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let elapsed =
                    ProcessInfo.processInfo.systemUptime - startTime
                let linear = min(
                    1,
                    elapsed
                        / NativeTimelineComponentButtonVisualState
                            .pressAnimationDuration
                )
                let progress =
                    MotionEasing
                        .easeOut(linear)
                self.componentButtonPressProgress =
                    start + (destination - start) * progress
                self.invalidateComponentButton(target)
                self.positionComponentButtonEmoji(target)
                if linear >= 1 {
                    self.componentButtonPressProgress = destination
                    self.componentButtonPressAnimationDestination = nil
                    self.componentButtonPressAnimationTask = nil
                    if destination == 0,
                       self.visualPressedComponentButton == target
                    {
                        self.visualPressedComponentButton = nil
                    }
                    self.invalidateComponentButton(target)
                    self.positionComponentButtonEmoji(target)
                    return
                }
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }

    /// Clears hover and press state; a cancelled press also returns its
    /// button's live emoji to rest.
    @discardableResult
    func clearPointerTargets() -> NativeTimelinePointerState.ClearedTargets {
        hoveredReaction = nil
        let cleared = pointer.clearHoverAndPressTargets()
        if let button = cleared.componentButton { positionComponentButtonEmoji(button) }
        return cleared
    }

    /// A live button emoji follows its button's dip; other overlays stay put.
    private func positionComponentButtonEmoji(_ target: NativeTimelineComponentButtonTarget) {
        guard let item = items.first(where: { $0.messageID == target.messageID }),
              animatedOverlayRoles(for: item.identifier).contains(where: { role in
                  if case .componentButton(_, target.componentID) = role { true } else { false }
              })
        else { return }
        positionAnimatedMediaOverlays()
    }

    func invalidateComponentButton(
        _ target: NativeTimelineComponentButtonTarget
    ) {
        guard let index = items.firstIndex(where: {
            $0.messageID == target.messageID
        }) else { return }
        setNeedsDisplay(fileCardDisplayFrame(target, at: index) ?? rowFrame(at: index))
    }
}
