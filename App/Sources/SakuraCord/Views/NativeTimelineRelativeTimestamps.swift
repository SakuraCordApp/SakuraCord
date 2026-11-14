import AppKit

extension NativeMessageTimelineCoordinator {
    func updateTimestampObservation() {
        timestampSources = items.reduce(into: [:]) { sources, item in
            let content = if let row = item.messageRow {
                TimestampMentionPresentation.sources(in: row.message, replyContent: row.replyPreview?.content)
            } else {
                // The beginning row shows the channel topic, which can hold timestamps too.
                item.beginning?.topic.flatMap { TimestampMentionPresentation.tokens(in: $0).isEmpty ? nil : [$0] } ?? []
            }
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
              let canvas, let scrollView, layoutWidth > 0,
              let visibleRange = visiblePreviewRange()
        else { return }
        // Rows out of view keep their labels until they scroll in, when the
        // next tick refreshes them, so a tick lays out only a screenful.
        let visibleIdentifiers = Set(items[visibleRange].map(\.identifier))
        let changedIdentifiers = Set(timestampSources.compactMap { identifier, source in
            guard visibleIdentifiers.contains(identifier) else { return nil as NativeMessageTimelineItem.Identifier? }
            let labels = source.reduce(into: [String: String]()) { result, text in
                result.merge(TimestampMentionPresentation.labels(in: text, at: date)) { _, latest in latest }
            }
            guard timestampLabels[identifier] != labels else { return nil as NativeMessageTimelineItem.Identifier? }
            timestampLabels[identifier] = labels
            return identifier
        })
        guard !changedIdentifiers.isEmpty else { return }
        isApplyingUpdate = true
        defer { isApplyingUpdate = false }
        relayRows(
            where: { changedIdentifiers.contains($0.identifier) },
            on: canvas, in: scrollView,
            // Deliberately bypass layoutPreparation and recent-conversation caches.
            layout: { NativeTimelineRowLayout.make(item: $0, width: layoutWidth, source: parent.model, relativeTo: date) }
        )
    }

    /// Lays out the rows `matches` selects again, keeping the reader in place
    /// when their heights change.
    func relayRows(
        where matches: (NativeMessageTimelineItem) -> Bool,
        on canvas: NativeTimelineCanvasView,
        in scrollView: NSScrollView,
        layout makeLayout: (NativeMessageTimelineItem) -> NativeTimelineRowLayout
    ) {
        cachedItemLayouts = cachedItemLayouts.filter { !matches($0.value.item) }
        let wasNearBottom = scrollState().isNearBottom
        let anchor = visibleAnchor()
        var changed = IndexSet()
        var changesHeight = false
        for index in items.indices where matches(items[index]) {
            let updated = makeLayout(items[index])
            changesHeight = changesHeight || abs(updated.height - rowHeights[index]) >= 0.5
            layouts[index] = updated
            rowHeights[index] = updated.height
            canvas.invalidateRowLayout(items[index].identifier)
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
