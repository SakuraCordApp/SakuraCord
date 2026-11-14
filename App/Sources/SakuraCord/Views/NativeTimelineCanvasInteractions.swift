import AppKit
import AVFoundation
import Combine
import CoreText
import ImageIO
import Lottie
import QuartzCore
import SakuraCordModels
import SwiftUI

extension NativeTimelineCanvasView {
    func handleComponentClick(
        in layout: NativeTimelineRowLayout,
        message: Message,
        point: CGPoint,
        rowIndex: Int
    ) -> Bool {
        for componentLayout in layout.componentLayouts {
            for container in componentLayout.containers
            where container.isSpoiler && container.frame.contains(point) {
                let key = NativeTimelineComponentRevealKey(
                    messageID: message.id,
                    componentID: container.componentID
                )
                if !spoilerRevealStore.isMediaRevealed(key) {
                    reveal(key, rowIndex: rowIndex)
                    return true
                }
            }
            // A file card's button and link act through their own pointer hit.
            for region in componentLayout.mediaRegions
            where region.frame.contains(point) {
                if case let .media(media) = region.kind, media.isVideo, !NativeTimelineSpoilerConcealmentPolicy.isConcealed(
                    messageID: message.id, contentID: region.componentID, isSpoiler: region.isSpoiler, store: spoilerRevealStore
                ) {
                    playInline(media.displayURL, mediaID: region.componentID, frame: region.frame, rowIndex: rowIndex) { [weak self] index, layout, message in
                        _ = self?.activateComponentMedia(region, layout: layout, message: message, rowIndex: index)
                    }
                    return true
                }
                return activateComponentMedia(region, layout: layout, message: message, rowIndex: rowIndex)
            }
            for region in componentLayout.selects
            where region.frame.contains(point) {
                guard !region.isDisabled else { return true }
                showComponentChoicePicker(
                    for: region,
                    message: message
                )
                return true
            }
        }
        return false
    }

    func activateComponentMedia(
        _ region: NativeTimelineComponentLayout.MediaRegion,
        layout: NativeTimelineRowLayout,
        message: Message,
        rowIndex: Int
    ) -> Bool {
        let id = region.componentID
        if NativeTimelineSpoilerConcealmentPolicy.isConcealed(
            messageID: message.id, contentID: id, isSpoiler: region.isSpoiler, store: spoilerRevealStore
        ) {
            reveal(NativeTimelineComponentRevealKey(messageID: message.id, componentID: id), rowIndex: rowIndex)
        } else if let presentation = MediaViewerPlan.components(
            in: message,
            layouts: layout.componentLayouts,
            selectedComponentID: id,
            isRevealed: spoilerRevealStore.isMediaRevealed(in: message.id)
        ) {
            model?.mediaViewerPresentation = mediaViewerPresentation(presentation, rowIndex: rowIndex)
        } else {
            NSWorkspace.shared.open(region.openURL)
        }
        return true
    }

    func handleTextClick(
        in layout: NativeTimelineRowLayout,
        message: Message?,
        point: CGPoint,
        rowIdentifier: NativeMessageTimelineItem.Identifier
    ) -> Bool {
        guard let pointerHit = textPointerHit(
            in: layout,
            point: point
        ) else { return false }
        return activateTextHit(
            pointerHit.hit,
            message: message,
            rowIdentifier: rowIdentifier,
            region: pointerHit.region,
            profileAnchor: textLinkAnchorFrame(
                for: pointerHit,
                in: layout,
                rowIdentifier: rowIdentifier
            )
        )
    }

    func textLinkAnchorFrame(
        for pointerHit: TextPointerHit,
        in layout: NativeTimelineRowLayout,
        rowIdentifier: NativeMessageTimelineItem.Identifier
    ) -> CGRect? {
        guard let index = items.firstIndex(where: {
            $0.identifier == rowIdentifier
        }),
            let textRegion = linkPointerTextRegions(
                for: items[index],
                layout: layout
            ).first(where: { $0.region == pointerHit.region }),
            pointerHit.hit.characterIndex >= 0,
            pointerHit.hit.characterIndex < textRegion.value.length
        else { return nil }
        var linkRange = NSRange(location: 0, length: 0)
        guard textRegion.value.attribute(
            .link,
            at: pointerHit.hit.characterIndex,
            longestEffectiveRange: &linkRange,
            in: NSRange(location: 0, length: textRegion.value.length)
        ) != nil,
            let localFrame = NativeTimelineTextHitTester.rangeFrame(
                value: textRegion.value,
                framesetter: textRegion.framesetter,
                frame: textRegion.frame,
                range: linkRange
            )
        else { return nil }
        return localFrame.offsetBy(
            dx: 0,
            dy: displayedRowOrigin(at: index)
        )
    }

    func textPointerHit(
        in layout: NativeTimelineRowLayout,
        point: CGPoint
    ) -> TextPointerHit? {
        if let frame = layout.contentFrame,
           let contentText = layout.contentText,
           let hit = NativeTimelineTextHitTester.hit(
               box: contentText,
               frame: NativeTimelineTextGeometry
                   .messageContentDrawingFrame(frame),
               point: point
           ),
           hit.mention != nil
                || hit.url != nil
                || hit.spoilerRange != nil
        {
            return TextPointerHit(hit: hit, region: .content)
        }
        if let translation = layout.translationRegion,
           let frame = translation.textFrame, let text = translation.text,
           let hit = NativeTimelineTextHitTester.hit(
               box: text,
               frame: NativeTimelineTextGeometry.messageContentDrawingFrame(frame), point: point
           ), hit.mention != nil || hit.url != nil || hit.spoilerRange != nil {
            return TextPointerHit(hit: hit, region: translation.regionID)
        }
        for embed in layout.embedRegions {
            for (textIndex, region) in embed.textRegions.enumerated() {
                if let hit = NativeTimelineTextHitTester.hit(
                    box: region.text,
                    frame: region.frame,
                    point: point
                ), hit.mention != nil
                    || hit.url != nil
                    || hit.spoilerRange != nil
                {
                    return TextPointerHit(
                        hit: hit,
                        region: .embed(
                           embedID: embed.embedID,
                           textIndex: textIndex
                       )
                    )
                }
            }
        }
        for (layoutIndex, component) in
            layout.componentLayouts.enumerated()
        {
            for (textIndex, region) in component.textRegions.enumerated() {
                if let hit = NativeTimelineTextHitTester.hit(
                    box: region.text,
                    frame: region.frame,
                    point: point
                ), hit.mention != nil
                    || hit.url != nil
                    || hit.spoilerRange != nil
                {
                    return TextPointerHit(
                        hit: hit,
                        region: .component(
                           layoutIndex: layoutIndex,
                           textIndex: textIndex
                       )
                    )
                }
            }
        }
        if let beginning = layout.beginningLayout,
           let hit = NativeTimelineTextHitTester.hit(
               box: beginning.descriptionBox,
               frame: beginning.descriptionFrame,
               point: point
           ), hit.mention != nil
               || hit.url != nil
               || hit.spoilerRange != nil
        {
            return TextPointerHit(hit: hit, region: .beginningDescription)
        }
        return nil
    }

    func activateTextHit(
        _ hit: NativeTimelineTextHit,
        message: Message?,
        rowIdentifier: NativeMessageTimelineItem.Identifier,
        region: NativeTimelineTextRegion,
        profileAnchor: CGRect? = nil
    ) -> Bool {
        if let spoilerRange = hit.spoilerRange,
           let key = textSpoilerRevealKey(
               itemIdentifier: rowIdentifier,
               region: region,
               rangeLocation: spoilerRange.location
           ), !spoilerRevealStore.isTextRevealed(key)
        {
            revealTextSpoiler(itemIdentifier: rowIdentifier, region: region, rangeLocation: spoilerRange.location)
            return true
        }
        if let mention = hit.mention, mention.isInteractive {
            let anchor = StablePopoverAnchor(
                sourceView: self
            ) { [weak self] in
                self?.mentionAnchorFrame(
                    rowIdentifier: rowIdentifier,
                    region: region,
                    characterIndex: hit.characterIndex,
                    rawToken: mention.rawToken
                )
            }
            activateMention(
                mention,
                message: message,
                anchor: anchor
            )
            return true
        }
        guard let url = hit.url else { return false }
        let presentSystemProfile: ((User) -> Void)? = profileAnchor.flatMap { anchor in
            message.map { sourceMessage in
                { [weak self] user in
                    self?.showMessageProfile(for: user, sourceMessage: sourceMessage, anchor: anchor)
                }
            }
        }
        return MessageLinkActivator.activate(
            url,
            model: model,
            sourceMessage: message,
            displayedText: hit.displayedText,
            presentSystemProfile: presentSystemProfile
        )
    }

    func revealTextSpoiler(
        itemIdentifier: NativeMessageTimelineItem.Identifier,
        region: NativeTimelineTextRegion,
        rangeLocation: Int
    ) {
        guard let key = textSpoilerRevealKey(
            itemIdentifier: itemIdentifier,
            region: region,
            rangeLocation: rangeLocation
        ),
              !spoilerRevealStore.isTextRevealed(key)
        else { return }
        if let index = items.firstIndex(where: { $0.identifier == itemIdentifier }),
           layouts.indices.contains(index),
           let text = selectableTextRegions(for: items[index], layout: layouts[index])
               .first(where: { $0.region == region })
        {
            let rowOrigin = displayedRowOrigin(at: index)
            fadeOutSpoilerCover(
                NativeTimelineTextHitTester.spoilerRegions(
                    value: text.value,
                    framesetter: text.framesetter,
                    frame: text.frame
                )
                .filter { $0.range.location == rangeLocation }
                .map { $0.frame.offsetBy(dx: 0, dy: rowOrigin) },
                cornerRadius: SpoilerAppearance.textCornerRadius,
                duration: SpoilerAppearance.textRevealDuration
            )
        }
        spoilerRevealStore.revealText(key)
    }

    func activateMention(
        _ mention: MentionPresentation,
        message: Message?,
        anchor: StablePopoverAnchor
    ) {
        guard let model else { return }
        switch mention.target {
        case .unresolved, .game, .command, .guildNavigation, .channel, .linkedChannel, .message:
            model.openMention(mention.target, fromMessageIn: message?.channelID)
        case let .user(id):
            let resolver = MessageMentionResolver(
                model: model,
                message: message
            )
            if let user = resolver.user(id) {
                showMentionProfile(
                    for: user,
                    sourceMessage: message,
                    anchor: anchor
                )
            }
        case let .role(id):
            showMentionRole(id, sourceMessage: message, anchor: anchor)
        }
    }

    func mentionAnchorFrame(
        rowIdentifier: NativeMessageTimelineItem.Identifier,
        region: NativeTimelineTextRegion,
        characterIndex: Int,
        rawToken: String
    ) -> CGRect? {
        guard let index = items.firstIndex(where: {
            $0.identifier == rowIdentifier
        }),
           layouts.indices.contains(index),
           let text = linkPointerTextRegions(for: items[index], layout: layouts[index])
               .first(where: { $0.region == region })
        else { return nil }
        return NativeTimelineTextHitTester.mentionAnchorFrame(
            value: text.value,
            framesetter: text.framesetter,
            frame: text.frame,
            characterIndex: characterIndex,
            rawToken: rawToken
        )?.offsetBy(
            dx: 0,
            dy: displayedRowOrigin(at: index)
        )
    }

    func showComponentChoicePicker(
        for region: NativeTimelineComponentLayout.SelectRegion,
        message: Message
    ) {
        guard let model else { return }
        let target = NativeTimelineComponentSelectTarget(messageID: message.id, componentID: region.componentID)
        // The canvas can receive another click before the hosted field is ready.
        // Treat it as the same toggle instead of replacing the opening overlay.
        if activeComponentChoiceTarget == target, let componentChoiceOverlay {
            componentChoiceOverlay.close(commit: true)
            return
        }
        closeComponentChoiceOverlay()
        let selectedOptions = model.componentSelection(
            messageID: message.id,
            customID: region.customID
        )
        let defaultOptions = region.kind == .string
            ? region.options.filter(\.isDefault)
            : model.resolvedDefaultComponentChoices(region.options, kind: region.kind, guildID: message.guildID)
        let initialSelection = Array(
            (selectedOptions ?? defaultOptions)
                .map(\.value)
                .prefix(max(1, region.maximumSelectionCount))
        )
        let initialOptions = initialComponentChoices(for: region, message: message, model: model)
        var pendingOptions = selectedOptions ?? defaultOptions
        let overlay = ComponentChoiceOverlayController(
            initialSelection: initialSelection,
            minimumSelectionCount: region.minimumSelectionCount,
            maximumSelectionCount: region.maximumSelectionCount,
            submit: { [weak self] values in
                guard let self else { return }
                model.setComponentSelection(pendingOptions, messageID: message.id, customID: region.customID)
                model.publishComponentSelectionPresentation()
                self.actions?.submitComponent(
                    message,
                    region.customID,
                    self.interactionKind(region.kind),
                    values
                )
            },
            onClose: { [weak self] in
                if model.componentSelection(
                    messageID: message.id,
                    customID: region.customID
                )?.map(\.value) != initialSelection
                {
                    model.publishComponentSelectionPresentation()
                }
                self?.componentChoiceOverlay = nil
                self?.activeComponentChoiceTarget = nil
                self?.needsDisplay = true
            }
        )
        componentChoiceOverlay = overlay
        activeComponentChoiceTarget = target
        needsDisplay = true
        guard let anchorRect = componentSelectAnchorRect(
            messageID: message.id,
            componentID: region.componentID
        ) else {
            overlay.close()
            return
        }
        let placement = ComponentChoiceOverlayController.placement(
            for: anchorRect,
            in: self
        )
        overlay.present(
            rootView: AnyView(ComponentChoicePicker(
                placeholder: region.placeholder,
                resultPlacement: placement,
                selectKind: region.kind,
                options: region.options,
                initialOptions: initialOptions,
                selectedOptions: selectedOptions,
                maximumSelectionCount: region.maximumSelectionCount,
                loader: { [weak model] query in
                    guard let model else {
                        throw CancellationError()
                    }
                    return try await model.componentChoices(
                        kind: region.kind,
                        query: query,
                        guildID: message.guildID,
                        channelID: message.channelID
                    )
                },
                selectionChanged: { [weak overlay] options in
                    pendingOptions = options
                    overlay?.updateSelection(options.map(\.value))
                },
                complete: { [weak overlay] values, reason in
                    overlay?.completeSelection(values, reason: reason)
                }
            )),
            in: self,
            placement: placement,
            anchorRectProvider: { [weak self] in
                self?.componentSelectAnchorRect(
                    messageID: message.id,
                    componentID: region.componentID
                )
            }
        )
    }

    func initialComponentChoices(
        for region: NativeTimelineComponentLayout.SelectRegion,
        message: Message,
        model: AppModel
    ) -> [ComponentSelectOption] {
        guard region.kind != .string else { return region.options }
        // Entity selects carry only their defaults; the choices are entities.
        let cached = model.cachedComponentChoices(
            kind: region.kind,
            guildID: message.guildID,
            channelTypes: region.channelTypes
        )
        let cachedValues = Set(cached.map(\.value))
        return model.resolvedDefaultComponentChoices(region.options, kind: region.kind, guildID: message.guildID)
            .filter { !cachedValues.contains($0.value) } + cached
    }

    func componentSelectAnchorRect(
        messageID: MessageID,
        componentID: String
    ) -> CGRect? {
        guard let rowIndex = rowIndex(forMessageID: messageID),
        layouts.indices.contains(rowIndex),
        let region = layouts[rowIndex].componentLayouts
            .flatMap(\.selects)
            .first(where: { $0.componentID == componentID })
        else { return nil }
        return region.frame.offsetBy(
            dx: 0,
            dy: displayedRowOrigin(at: rowIndex)
        )
    }

    func closeComponentChoiceOverlay() {
        componentChoiceOverlay?.close()
        componentChoiceOverlay = nil
    }

    func interactionKind(
        _ kind: ComponentSelectKind
    ) -> ComponentInteractionKind {
        switch kind {
        case .string: .stringSelect
        case .user: .userSelect
        case .role: .roleSelect
        case .mentionable: .mentionableSelect
        case .channel: .channelSelect
        }
    }

    func presentActionError(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
