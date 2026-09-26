import AppKit
import Foundation

extension NativeMessageTimelineCoordinator {
    final class LayoutPreparation {
        var parent: NativeMessageTimelineView
        let rowsRevision: UInt64
        let presentationRevision: UInt64
        let fontRevision: UInt64
        let inviteRevision: UInt64
        let width: CGFloat
        var layouts: [NativeMessageTimelineItem.Identifier: CachedItemLayout] = [:]
        var isComplete = false

        init(parent: NativeMessageTimelineView, width: CGFloat) {
            self.parent = parent
            rowsRevision = parent.rowsRevision
            presentationRevision = parent.presentationRevision
            fontRevision = ProfileNameFontCache.revision
            inviteRevision = parent.model.serverInvites.revision
            self.width = width
        }

        func matches(_ parent: NativeMessageTimelineView, width: CGFloat) -> Bool {
            self.parent.model === parent.model
                && self.parent.conversation == parent.conversation
                && rowsRevision == parent.rowsRevision
                && presentationRevision == parent.presentationRevision
                && fontRevision == ProfileNameFontCache.revision
                && inviteRevision == parent.model.serverInvites.revision
                && abs(self.width - width) < 0.5
        }
    }

    /// Prepare large updates in short slices, keeping the existing geometry
    /// and scroll anchor intact until the complete update can be installed.
    func prepareLayoutsIfNeeded(
        parent newParent: NativeMessageTimelineView,
        scrollView: NSScrollView
    ) -> Bool {
        let width = max(220, scrollView.contentView.bounds.width.rounded())
        guard newParent.model === parent.model,
              newParent.conversation == parent.conversation,
              newParent.scrollRequest == parent.scrollRequest,
              pendingLayoutWidth == nil,
              abs(width - layoutWidth) < 0.5,
              rowCount > 0,
              (newParent.rowsUpdateJournal.latestRevision ?? newParent.rowsRevision)
                == newParent.rowsRevision
        else {
            cancelLayoutPreparation()
            return false
        }

        if let preparation = layoutPreparation,
           preparation.matches(newParent, width: width) {
            preparation.parent = newParent
            return !preparation.isComplete
        }
        cancelLayoutPreparation()
        guard canvas?.suppressesHoverPresentation == true else { return false }

        let newRows = newParent.conversation.rows(in: newParent.model)
        let pendingItems: [NativeMessageTimelineItem]
        if newParent.presentationRevision != presentationRevision {
            pendingItems = newParent.rowsRevision != rowsRevision
                ? makeItems(from: newParent, rows: newRows)
                : items
            guard pendingItems.count >= 32 else { return false }
        } else {
            let count = newRows.count - rowCount
            guard newParent.rowsRevision != rowsRevision,
                  (32 ... 200).contains(count),
                  newRows[count].id == firstRowID,
                  newRows.last?.id == lastRowID
            else { return false }
            pendingItems = newRows.prefix(count).map {
                messageItem($0, from: newParent)
            }
        }

        // This buffer belongs only to this pending update. Unlike the bounded
        // recent-conversation cache, it must hold a complete presentation
        // update even when the timeline has more rows than that cache's limit.
        let preparation = LayoutPreparation(parent: newParent, width: width)
        preparation.layouts.reserveCapacity(pendingItems.count)
        layoutPreparation = preparation
        layoutPreparationTask = Task { @MainActor [weak self, weak scrollView] in
            guard let self, let scrollView else { return }
            var sliceStart = ProcessInfo.processInfo.systemUptime
            for item in pendingItems {
                guard !Task.isCancelled,
                      self.layoutPreparation === preparation
                else { return }
                guard preparation.matches(
                    preparation.parent,
                    width: max(220, scrollView.contentView.bounds.width.rounded())
                ), abs(self.layoutWidth - width) < 0.5
                else {
                    self.layoutPreparationTask = nil
                    self.layoutPreparation = nil
                    self.applyUpdate(parent: preparation.parent, scrollView: scrollView)
                    return
                }
                let prepared = AppPerformanceSignposts.measureSync(
                    "TimelineLayoutPreparation"
                ) {
                    self.cachedItemLayout(
                        for: item, width: width,
                        presentationRevision: preparation.presentationRevision
                    ) ?? NativeTimelineRowLayout.make(
                        item: item, width: width, model: preparation.parent.model
                    )
                }
                preparation.layouts[item.identifier] = CachedItemLayout(
                    item: item, layout: prepared
                )
                if ProcessInfo.processInfo.systemUptime - sliceStart >= 0.0015 {
                    // Let AppKit service its display link; yielding alone can
                    // resume the same job before the run loop services drawing.
                    do {
                        try await Task.sleep(for: .milliseconds(1))
                    } catch {
                        return
                    }
                    sliceStart = ProcessInfo.processInfo.systemUptime
                }
            }
            guard !Task.isCancelled,
                  self.layoutPreparation === preparation
            else { return }
            preparation.isComplete = true
            self.layoutPreparationTask = nil
            self.applyUpdate(parent: preparation.parent, scrollView: scrollView)
        }
        return true
    }

    func cancelLayoutPreparation() {
        layoutPreparationTask?.cancel()
        layoutPreparationTask = nil
        layoutPreparation = nil
    }
}
