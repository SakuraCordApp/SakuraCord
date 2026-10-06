import AppKit

extension NativeMessageTimelineCoordinator {
    func updateTimestampObservation() {
        timestampSources = items.reduce(into: [:]) { sources, item in
            guard let row = item.messageRow else { return }
            let content = TimestampMentionPresentation.sources(in: row.message, replyContent: row.replyPreview?.content)
            guard !content.isEmpty else { return }
            sources[item.identifier] = content
        }
        timestampLabels = timestampLabels.filter { timestampSources[$0.key] != nil }
        timestampWindowChanged()
    }

    func timestampWindowChanged() {
        guard scrollView?.window != nil, !timestampSources.isEmpty else {
            RelativeTimestampClock.shared.remove(self)
            return
        }
        RelativeTimestampClock.shared.observe(self) { [weak self] date in
            self?.refreshTimestampPresentation(at: date)
        }
        refreshTimestampPresentation(at: .now)
    }

    func refreshTimestampPresentation(at date: Date) {
        guard let scrollView, let window = scrollView.window,
              window.occlusionState.contains(.visible), !scrollView.isHiddenOrHasHiddenAncestor
        else { return }
        refreshTimestampLayouts(at: date)
    }

    func refreshTimestampLayouts(at date: Date) {
        guard !isApplyingUpdate, layoutPreparation == nil, pendingLayoutWidth == nil,
              let canvas, let scrollView, layoutWidth > 0
        else { return }
        let changedIdentifiers = Set(timestampSources.compactMap { identifier, source in
            let labels = source.reduce(into: [String: String]()) { result, text in
                result.merge(TimestampMentionPresentation.labels(in: text, at: date)) { _, latest in latest }
            }
            guard timestampLabels[identifier] != labels else { return nil as NativeMessageTimelineItem.Identifier? }
            timestampLabels[identifier] = labels
            return identifier
        })
        guard !changedIdentifiers.isEmpty else { return }
        cachedItemLayouts = cachedItemLayouts.filter { !changedIdentifiers.contains($0.key.identifier) }
        let wasNearBottom = scrollState().isNearBottom
        let anchor = visibleAnchor()
        var changed = IndexSet()
        var changesHeight = false
        isApplyingUpdate = true
        defer { isApplyingUpdate = false }
        for index in items.indices where changedIdentifiers.contains(items[index].identifier) {
            // Deliberately bypass layoutPreparation and recent-conversation caches.
            let updated = NativeTimelineRowLayout.make(
                item: items[index], width: layoutWidth, model: parent.model, relativeTo: date
            )
            changesHeight = changesHeight || abs(updated.height - rowHeights[index]) >= 0.5
            layouts[index] = updated
            rowHeights[index] = updated.height
            canvas.invalidateBitmap(items[index].identifier)
            canvas.mentionPointerRegionCache[items[index].identifier] = nil
            canvas.codeBlockPointerRegionCache[items[index].identifier] = nil
            canvas.accessibilityProxies.remove(items[index].identifier)
            changed.insert(index)
        }
        guard !changed.isEmpty else { return }
        if changesHeight { rebuildOrigins() }
        applySnapshot(to: canvas, in: scrollView)
        canvas.window?.invalidateCursorRects(for: canvas)
        if changesHeight {
            canvas.invalidateVisibleContent()
            if wasNearBottom {
                _ = scroll(to: .bottom, in: scrollView)
            } else if let anchor {
                restore(anchor)
            }
        } else {
            canvas.invalidateRows(changed)
        }
    }
}
