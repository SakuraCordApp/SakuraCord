import AppKit
import MessageRendering
import SakuraCordModels
import SwiftUI

extension NativeTimelineCanvasView {
    func timelineTextCaret(
        at point: CGPoint,
        itemIdentifier: NativeMessageTimelineItem.Identifier?,
        region requestedRegion: NativeTimelineTextRegion?,
        clampsToText: Bool,
        requiresPointInTextContainer: Bool
    ) -> TextCaretCandidate? {
        let index: Int?
        if let itemIdentifier {
            index = items.firstIndex {
                $0.identifier == itemIdentifier
            }
        } else {
            index = rowIndex(at: point.y)
        }
        guard let index,
              items.indices.contains(index),
              layouts.indices.contains(index),
              itemIdentifier == nil
                  || items[index].identifier == itemIdentifier
        else { return nil }
        let local = CGPoint(
            x: point.x,
            y: point.y - displayedRowOrigin(at: index)
        )
        for selectable in selectableTextRegions(
            for: items[index],
            layout: layouts[index]
        )
        where requestedRegion == nil || selectable.region == requestedRegion {
            if requiresPointInTextContainer {
                let interactionFrame = textSelectionInteractionFrame(
                    region: selectable.region,
                    frame: selectable.interactionFrame,
                    rowIndex: index
                )
                guard interactionFrame.contains(point) else { continue }
            }
            guard let caret = NativeTimelineTextHitTester.caretIndex(
                value: selectable.value,
                framesetter: selectable.framesetter,
                frame: selectable.frame,
                point: local,
                clampsToText: clampsToText
            ) else { continue }
            return TextCaretCandidate(
                itemIdentifier: items[index].identifier,
                region: selectable.region,
                rowIndex: index,
                caret: caret,
                value: selectable.value
            )
        }
        return nil
    }

    func textSelectionInteractionFrame(
        region: NativeTimelineTextRegion,
        frame: CGRect,
        rowIndex: Int
    ) -> CGRect {
        guard region == .content else {
            return frame.offsetBy(
                dx: 0,
                dy: displayedRowOrigin(at: rowIndex)
            )
        }
        return NativeTimelineTextSelectionGeometry.interactionFrame(
            contentFrame: frame,
            rowOrigin: displayedRowOrigin(at: rowIndex),
            canvasWidth: bounds.width
        )
    }

    func selectableTextRegions(
        for item: NativeMessageTimelineItem,
        layout: NativeTimelineRowLayout
    ) -> [SelectableTextRegion] {
        textRegions(
            for: item,
            layout: layout,
            includesNonSelectable: false
        )
    }

    func linkPointerTextRegions(
        for item: NativeMessageTimelineItem,
        layout: NativeTimelineRowLayout
    ) -> [SelectableTextRegion] {
        textRegions(
            for: item,
            layout: layout,
            includesNonSelectable: true
        )
    }

    private func textRegions(
        for item: NativeMessageTimelineItem,
        layout: NativeTimelineRowLayout,
        includesNonSelectable: Bool
    ) -> [SelectableTextRegion] {
        var result: [SelectableTextRegion] = []
        if case let .beginning(beginning) = item,
           let beginningLayout = layout.beginningLayout
        {
            let title = NativeTimelineBeginningText.title(beginning)
            result.append(SelectableTextRegion(
                region: .beginningTitle,
                frame: beginningLayout.titleFrame,
                interactionFrame: beginningLayout.titleFrame,
                value: title.value,
                framesetter: title.framesetter
            ))
            if beginning.isDescriptionSelectable || includesNonSelectable {
                let description = beginningLayout.descriptionBox
                result.append(SelectableTextRegion(
                    region: .beginningDescription,
                    frame: beginningLayout.descriptionFrame,
                    interactionFrame: beginningLayout.descriptionFrame,
                    value: description.value,
                    framesetter: description.framesetter
                ))
            }
            return result
        }
        if let frame = layout.contentFrame, let text = layout.contentText {
            result.append(SelectableTextRegion(
                region: .content,
                frame: NativeTimelineTextGeometry
                    .messageContentDrawingFrame(frame),
                interactionFrame: frame,
                value: text.value,
                framesetter: text.framesetter
            ))
        }
        if let translation = layout.translationRegion,
           let frame = translation.textFrame, let text = translation.text {
            result.append(SelectableTextRegion(
                region: translation.regionID,
                frame: NativeTimelineTextGeometry.messageContentDrawingFrame(frame),
                interactionFrame: frame, value: text.value, framesetter: text.framesetter
            ))
        }
        for embed in layout.embedRegions {
            for (textIndex, textRegion) in
                embed.textRegions.enumerated()
            where includesNonSelectable || textRegion.isSelectable {
                let frame = textRegion.text.drawingFrame(textRegion.frame)
                result.append(SelectableTextRegion(
                    region: .embed(
                        embedID: embed.embedID,
                        textIndex: textIndex
                    ),
                    frame: frame,
                    interactionFrame: textRegion.frame,
                    value: textRegion.text.value,
                    framesetter: textRegion.text.framesetter
                ))
            }
        }
        for (layoutIndex, component) in
            layout.componentLayouts.enumerated()
        {
            for (textIndex, textRegion) in
                component.textRegions.enumerated()
            where includesNonSelectable || textRegion.isSelectable {
                let frame = textRegion.text.drawingFrame(textRegion.frame)
                result.append(SelectableTextRegion(
                    region: .component(
                        layoutIndex: layoutIndex,
                        textIndex: textIndex
                    ),
                    frame: frame,
                    interactionFrame: textRegion.frame,
                    value: textRegion.text.value,
                    framesetter: textRegion.text.framesetter
                ))
            }
        }
        return result
    }

    func setTextSelection(
        _ selection: NativeTimelineTextSelection?
    ) {
        guard pointer.textSelection != selection else { return }
        let oldIdentifier = pointer.textSelection?.itemIdentifier
        pointer.textSelection = selection
        positionAnimatedMediaOverlays()
        reconcileBeginningSelectionOverlay()
        for identifier
            in [oldIdentifier, selection?.itemIdentifier].compactMap({
            $0
        }) {
            guard let index = items.firstIndex(where: {
                $0.identifier == identifier
            }) else { continue }
            setNeedsDisplay(rowFrame(at: index))
        }
    }

    func reconcileBeginningSelectionOverlay() {
        guard let selection = pointer.textSelection,
              let index = items.firstIndex(where: {
                  $0.identifier == selection.itemIdentifier
              }),
              layouts.indices.contains(index),
              case let .beginning(beginning) = items[index],
              let layout = layouts[index].beginningLayout
        else {
            beginningSelectionOverlay.image = nil
            beginningSelectionOverlay.isHidden = true
            return
        }

        let box: NativeTimelineAttributedTextBox
        let localFrame: CGRect
        let revealedLocations: Set<Int>
        switch selection.region {
        case .beginningTitle:
            box = NativeTimelineBeginningText.title(beginning)
            localFrame = layout.titleFrame
            revealedLocations = []
        case .beginningDescription:
            box = layout.descriptionBox
            localFrame = layout.descriptionFrame
            revealedLocations = textSpoilerRevealState(at: index).locations(in: .beginningDescription)
        default:
            beginningSelectionOverlay.image = nil
            beginningSelectionOverlay.isHidden = true
            return
        }

        let overlayFrame = box.drawingFrame(localFrame.offsetBy(
            dx: 0,
            dy: displayedRowOrigin(at: index)
        ))
        beginningSelectionOverlay.frame = overlayFrame
        beginningSelectionOverlay.image =
            NativeTimelineRowPainter.selectionOverlayImage(
                box,
                size: overlayFrame.size,
                selectionRange: selection.range,
                revealedSpoilerLocations: revealedLocations
            )
        beginningSelectionOverlay.isHidden = false
    }

    func selectedTextValue() -> String? {
        guard let selection = pointer.textSelection,
              selection.range.length > 0,
              let index = items.firstIndex(where: {
                  $0.identifier == selection.itemIdentifier
              }),
              layouts.indices.contains(index),
              let value = selectableTextRegions(
                  for: items[index],
                  layout: layouts[index]
              )
                  .first(where: {
                      $0.region == selection.region
                  })?.value,
              selection.range.location >= 0,
              NSMaxRange(selection.range) <= value.length
        else { return nil }
        return RichMessageCopySerializer.string(
            from: value,
            range: selection.range
        )
    }

    static func wordRange(
        at caret: Int,
        in string: String
    ) -> NSRange {
        let value = string as NSString
        guard value.length > 0 else { return NSRange(location: 0, length: 0) }
        var index = min(max(0, caret), value.length - 1)
        if value.character(at: index) == 0xFFFC {
            return NSRange(location: index, length: 1)
        }
        let wordCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "_")
        )
        func isWordCharacter(at location: Int) -> Bool {
            let range = value.rangeOfComposedCharacterSequence(
                at: location
            )
            return value.substring(with: range).rangeOfCharacter(
                from: wordCharacters
            ) != nil
        }
        guard isWordCharacter(at: index) else {
            return value.rangeOfComposedCharacterSequence(at: index)
        }
        var start = index
        while start > 0 {
            let previous = value.rangeOfComposedCharacterSequence(
                at: start - 1
            )
            guard isWordCharacter(at: previous.location) else { break }
            start = previous.location
        }
        var end = NSMaxRange(
            value.rangeOfComposedCharacterSequence(at: index)
        )
        while end < value.length, isWordCharacter(at: end) {
            end = NSMaxRange(
                value.rangeOfComposedCharacterSequence(at: end)
            )
        }
        index = start
        return NSRange(location: index, length: end - index)
    }

    func messageLink(for message: Message) -> String {
        DiscordLink.message(
            guildID: message.guildID ?? model?.selectedGuildID, channelID: message.channelID, messageID: message.id
        )
    }
}
