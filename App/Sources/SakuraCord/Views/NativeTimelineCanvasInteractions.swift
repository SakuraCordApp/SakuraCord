import AppKit
import SakuraCordModels
import SwiftUI

extension NativeTimelineCanvasView {
    func activateMessageContent(
        _ target: NativeTimelinePointerActivationTarget,
        message: Message,
        layout: NativeTimelineRowLayout,
        rowIndex: Int
    ) -> Bool {
        switch target {
        case let .componentReveal(_, componentID):
            reveal(NativeTimelineComponentRevealKey(messageID: message.id, componentID: componentID), rowIndex: rowIndex)
        // A file card's button and link act through their own pointer hit.
        case let .componentImage(_, _, payload), let .componentMedia(_, _, payload), let .componentFile(_, _, payload):
            let region = payload.value
            guard case let .media(media) = region.kind, media.isVideo, !spoilerRevealStore.isConcealed(
                messageID: message.id, contentID: region.componentID, isSpoiler: region.isSpoiler
            ) else { return activateComponentMedia(region, layout: layout, message: message, rowIndex: rowIndex) }
            playInline(media.displayURL, mediaID: region.componentID, frame: region.frame, rowIndex: rowIndex) { [weak self] index, layout, message in
                _ = self?.activateComponentMedia(region, layout: layout, message: message, rowIndex: index)
            }
        case let .componentSelect(_, _, region):
            if !region.value.isDisabled {
                showComponentChoicePicker(for: region.value, message: message)
            }
        case let .linkedImage(_, _, region):
            return activateLinkedImage(region.value, in: message, rowIndex: rowIndex)
        case let .attachment(_, _, region):
            let attachment = region.value.attachment
            guard attachment.mediaKind == .video,
                  !spoilerRevealStore.isConcealed(attachment, in: message.id)
            else { return activateAttachment(attachment, in: message, rowIndex: rowIndex) }
            playInline(
                attachment.proxyURL ?? attachment.url, mediaID: attachment.id,
                frame: region.value.frame, rowIndex: rowIndex
            ) { [weak self, attachmentID = attachment.id] index, layout, message in
                guard let region = layout.attachmentRegions.first(where: { $0.attachment.id == attachmentID }) else { return }
                _ = self?.openAttachmentInViewer(region.attachment, message: message, rowIndex: index)
            }
        case let .embedMedia(_, _, region):
            _ = activateEmbedMedia(region.value, in: message, rowIndex: rowIndex)
        case .thread:
            guard let thread = message.thread else { return false }
            actions?.openThread(thread)
        default:
            return false
        }
        return true
    }

    func activateComponentMedia(
        _ region: NativeTimelineComponentLayout.MediaRegion,
        layout: NativeTimelineRowLayout,
        message: Message,
        rowIndex: Int
    ) -> Bool {
        let id = region.componentID
        if spoilerRevealStore.isConcealed(messageID: message.id, contentID: id, isSpoiler: region.isSpoiler) {
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

    func activateLinkedImage(
        _ region: NativeTimelineRowLayout.LinkedImageRegion,
        in message: Message,
        rowIndex: Int
    ) -> Bool {
        if let presentation = MediaViewerPlan.linkedImages(
            in: message,
            selectedReferenceID: region.reference.id
        ) {
            model?.mediaViewerPresentation = mediaViewerPresentation(presentation, rowIndex: rowIndex)
        } else {
            NSWorkspace.shared.open(region.reference.url)
        }
        return true
    }

    func activateAttachment(
        _ attachment: Attachment,
        in message: Message,
        rowIndex: Int
    ) -> Bool {
        if spoilerRevealStore.isConcealed(attachment, in: message.id) {
            reveal(.attachment(messageID: message.id, attachmentID: attachment.id), rowIndex: rowIndex)
        } else if !openAttachmentInViewer(attachment, message: message, rowIndex: rowIndex) {
            NSWorkspace.shared.open(attachment.url)
        }
        return true
    }

    func activateEmbedMedia(
        _ region: NativeTimelineRowLayout.EmbedRegion,
        in message: Message,
        rowIndex: Int
    ) -> Bool {
        if openEmbedMediaInViewer(id: region.embedID, message: message, rowIndex: rowIndex) { return true }
        guard let url = region.mediaURL else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    func activateComponentButton(
        _ region: NativeTimelineComponentLayout.ButtonRegion,
        message: Message
    ) -> Bool {
        guard !region.isDisabled else { return false }
        if let url = region.url {
            return MessageLinkActivator.activate(url, model: model)
        }
        guard let customID = region.customID else { return false }
        if model?.presentIssueReport(forComponent: customID, on: message) == true { return true }
        actions?.submitComponent(message, customID, .button, [])
        return true
    }
}
