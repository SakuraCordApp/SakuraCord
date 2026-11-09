import AppKit
import CoreServices
import CoreText

extension NativeTimelineCanvasView {
    override func pressureChange(with event: NSEvent) {
        // Force Click has its own pressure stream; AppKit does not turn it
        // into the Quick Look event used by a three-finger tap for this view.
        guard event.stage == 2,
              !pointer.didForceClickLookup,
              !didDragTextSelection,
              textSelectionGesture != nil,
              UserDefaults.standard.object(forKey: "com.apple.trackpad.forceClick") as? Bool ?? true,
              let lookup = dictionaryLookupAction(at: convert(event.locationInWindow, from: nil))
        else { return }
        pointer.didForceClickLookup = true
        textSelectionGesture = nil
        pressedActivationTarget = nil
        lookup()
    }

    override func quickLook(with event: NSEvent) {
        if let lookup = dictionaryLookupAction(at: convert(event.locationInWindow, from: nil)) {
            lookup()
        } else {
            super.quickLook(with: event)
        }
    }

    func dictionaryLookupAction(at point: CGPoint, usesSelection: Bool = false) -> (() -> Void)? {
        guard !glideBlocksPointer,
              WindowModalCoordinator.allowsInput(for: self),
              !overlayBlocksInteractions,
              editingMessageID == nil
        else { return nil }
        guard let index = rowIndex(at: point.y),
              items.indices.contains(index),
              layouts.indices.contains(index),
              items[index].messageID != nil
        else {
            return nil
        }
        let local = CGPoint(x: point.x, y: point.y - displayedRowOrigin(at: index))
        for text in selectableTextRegions(for: items[index], layout: layouts[index]) {
            guard let hit = NativeTimelineTextHitTester.hit(
                value: text.value,
                framesetter: text.framesetter,
                frame: text.frame,
                point: local,
                targetsTextCharacters: true
            ), hit.mention == nil,
                text.value.attribute(.attachment, at: hit.characterIndex, effectiveRange: nil) == nil
            else { continue }
            guard let lookupRange = dictionaryLookupRange(
                in: text,
                itemIdentifier: items[index].identifier,
                characterIndex: hit.characterIndex
            ) else { return nil }
            let lookupText = text.value.attributedSubstring(from: lookupRange)
            let lookupIndex = hit.characterIndex - lookupRange.location
            let term = DCSGetTermRangeInString(nil, lookupText.string as CFString, lookupIndex)
            var word = term.location == kCFNotFound
                ? Self.wordRange(at: lookupIndex, in: lookupText.string)
                : NSRange(location: term.location, length: term.length)
            if usesSelection, let selection = textSelection,
               selection.itemIdentifier == items[index].identifier,
               selection.region == text.region,
               NSLocationInRange(hit.characterIndex, selection.range)
            {
                let visibleSelection = NSIntersectionRange(selection.range, lookupRange)
                word = NSRange(
                    location: visibleSelection.location - lookupRange.location,
                    length: visibleSelection.length
                )
            }
            guard word.length > 0,
                  let anchor = NativeTimelineTextHitTester.rangeFrame(
                      value: text.value,
                      framesetter: text.framesetter,
                      frame: text.frame,
                      range: NSRange(
                          location: lookupRange.location + word.location,
                          length: word.length
                      )
                  )
            else { continue }
            let substring = (lookupText.string as NSString).substring(with: word)
            guard substring.rangeOfCharacter(from: .letters) != nil else { continue }
            let rowOrigin = displayedRowOrigin(at: index)
            // AppKit's automatic expansion of a zero-length range can silently
            // fail for custom-drawn text. Resolve the system dictionary term first.
            return { [weak self] in
                guard let self,
                      !self.glideBlocksPointer,
                      WindowModalCoordinator.allowsInput(for: self),
                      !self.overlayBlocksInteractions,
                      self.editingMessageID == nil
                else { return }
                self.showDefinition(
                    for: lookupText,
                    range: word,
                    options: nil
                ) { adjustedRange in
                    let originalLocation = lookupRange.location + adjustedRange.location
                    let firstCharacter = NSRange(location: originalLocation, length: 1)
                    let frame = NativeTimelineTextHitTester.rangeFrame(
                        value: text.value,
                        framesetter: text.framesetter,
                        frame: text.frame,
                        range: firstCharacter
                    ) ?? anchor
                    let font = text.value.attribute(
                        .font,
                        at: min(originalLocation, text.value.length - 1),
                        effectiveRange: nil
                    ) as? NSFont
                    return NSPoint(
                        x: frame.minX,
                        y: frame.maxY + (font?.descender ?? 0) + rowOrigin
                    )
                }
            }
        }
        return nil
    }

    private func dictionaryLookupRange(
        in text: SelectableTextRegion,
        itemIdentifier: NativeMessageTimelineItem.Identifier,
        characterIndex: Int
    ) -> NSRange? {
        var lowerBound = 0
        var upperBound = text.value.length
        // AppKit may expand a lookup to surrounding words. Bound its input
        // at hidden spoilers so that expansion cannot reveal their contents.
        for range in NativeTimelineTextSpoilers.ranges(in: text.value) {
            if let key = textSpoilerRevealKey(
                itemIdentifier: itemIdentifier,
                region: text.region,
                rangeLocation: range.location
            ), spoilerRevealStore.isTextRevealed(key) {
                continue
            }
            if NSMaxRange(range) <= characterIndex {
                lowerBound = max(lowerBound, NSMaxRange(range))
            } else {
                upperBound = min(upperBound, range.location)
            }
        }
        guard characterIndex >= lowerBound, characterIndex < upperBound else { return nil }
        return NSRange(location: lowerBound, length: upperBound - lowerBound)
    }
}
