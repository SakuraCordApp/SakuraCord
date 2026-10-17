import AppKit
import OSLog
import SakuraCordModels
import SwiftUI

extension NativeMessageTimelineCoordinator {
        func applyJournalUpdate(
            from oldParent: NativeMessageTimelineView,
            to newParent: NativeMessageTimelineView,
            rows newRows: [MessageRowPresentation],
            width: CGFloat
        ) -> Bool {
            guard oldParent.conversation == newParent.conversation,
                  newParent.rowsRevision > rowsRevision
            else { return false }
            guard !NativeMessageTimelineLayoutPolicy
                .requiresFirstMessageBoundaryRebuild(
                    from: oldParent.firstMessageStartsDayOverride,
                    to: newParent.firstMessageStartsDayOverride
                )
            else {
                performanceFallbackReason = "journal-first-message-boundary"
                return false
            }
            guard let records = newParent.rowsUpdateJournal.records(
                after: rowsRevision,
                through: newParent.rowsRevision
            ) else {
                performanceFallbackReason = "journal-unavailable"
                return false
            }
            let expectedCount = Int(newParent.rowsRevision - rowsRevision)
            guard records.count == expectedCount,
                  records.first?.revision == rowsRevision &+ 1,
                  records.last?.revision == newParent.rowsRevision,
                  !records.contains(where: \.invalidatesAllRows)
            else {
                let hasReload = records.contains(
                    where: \.invalidatesAllRows
                )
                performanceFallbackReason =
                    "journal old=\(rowsRevision) new=\(newParent.rowsRevision) records=\(records.count) expected=\(expectedCount) reload=\(hasReload)"
                return false
            }

            if newParent.conversation == .inbox(.unread) {
                let oldByID = Dictionary(uniqueKeysWithValues: zip(items, layouts).map { ($0.identifier, ($0, $1)) })
                let newItems = makeItems(from: newParent, rows: newRows)
                layouts = newItems.map { item in
                    if let prior = oldByID[item.identifier], prior.0 == item { return prior.1 }
                    return layoutUsingRecentConversationCache(for: item, width: width, presentationRevision: newParent.presentationRevision)
                }
                items = newItems
                messageIDs = newRows.map(\.id)
                storage.invalidateItemIndex()
                rowHeights = layouts.map(\.height)
                didMutateItems = true
                requiresVisibleRedraw = true
                requiresAnchorRestore = true
                requiresFullOriginRebuild = true
                performanceUpdatePath = "inbox-journal"
                return true
            }

            let changedMessageIDs = journalChangedMessageIDs(
                records: records,
                oldParent: oldParent,
                newParent: newParent
            )
            let oldLeadingCount = items.count - rowCount
            guard oldLeadingCount >= 0 else { return false }
            let leadingItems = makeLeadingItems(from: newParent)
            guard leadingItems.count == oldLeadingCount else {
                performanceFallbackReason = "journal-leading-count"
                return false
            }
            guard items.count - oldLeadingCount == rowCount else {
                performanceFallbackReason = "journal-invalid-row-count"
                return false
            }
            guard messageIDs.count == rowCount else {
                performanceFallbackReason = "journal-invalid-id-count"
                return false
            }

            guard let mutationIDs = validatedJournalMutationIDs(records) else { return false }
            guard let identityChanges = validatedJournalIdentityChanges(
                rows: newRows,
                oldLeadingCount: oldLeadingCount,
                insertedMessageIDs: mutationIDs.inserted,
                removedMessageIDs: mutationIDs.removed
            ) else { return false }

            applyJournalMutation(
                to: newParent,
                rows: newRows,
                plan: JournalMutationPlan(
                    leadingItems: leadingItems,
                    oldLeadingCount: oldLeadingCount,
                    changedMessageIDs: changedMessageIDs,
                    identityChanges: identityChanges
                ),
                width: width
            )
            return true
        }

        func journalChangedMessageIDs(
            records: ArraySlice<MessageRowsUpdateRecord>,
            oldParent: NativeMessageTimelineView,
            newParent: NativeMessageTimelineView
        ) -> Set<MessageID> {
            var ids = records.reduce(into: Set<MessageID>()) {
                $0.formUnion($1.changedMessageIDs)
            }
            if oldParent.unreadMessageID != newParent.unreadMessageID {
                ids.formUnion([oldParent.unreadMessageID, newParent.unreadMessageID].compactMap { $0 })
            }
            if oldParent.selectedMessageID != newParent.selectedMessageID {
                ids.formUnion(
                    [oldParent.selectedMessageID, newParent.selectedMessageID].compactMap { $0 }
                )
            }
            return ids
        }

        func validatedJournalMutationIDs(
            _ records: ArraySlice<MessageRowsUpdateRecord>
        ) -> JournalMutationIDs? {
            var inserted = Set<MessageID>()
            var removed = Set<MessageID>()
            for record in records {
                switch record.change {
                case let .some(.insert(indexes)):
                    guard indexes.count == record.insertedMessageIDs.count,
                          record.removedMessageIDs.isEmpty
                    else {
                        performanceFallbackReason = "journal-invalid-insert"
                        return nil
                    }
                    inserted.formUnion(record.insertedMessageIDs)
                case let .some(.remove(removedIndexes, _)):
                    guard removedIndexes.count == record.removedMessageIDs.count,
                          record.insertedMessageIDs.isEmpty
                    else {
                        performanceFallbackReason = "journal-invalid-remove"
                        return nil
                    }
                    removed.formUnion(record.removedMessageIDs)
                case .some(.replace):
                    guard record.insertedMessageIDs.isEmpty,
                          record.removedMessageIDs.isEmpty
                    else {
                        performanceFallbackReason = "journal-invalid-replace"
                        return nil
                    }
                case .none:
                    guard record.insertedMessageIDs.isEmpty,
                          record.removedMessageIDs.isEmpty
                    else {
                        performanceFallbackReason = "journal-missing-change"
                        return nil
                    }
                }
            }
            return JournalMutationIDs(inserted: inserted, removed: removed)
        }

        func validatedJournalIdentityChanges(
            rows newRows: [MessageRowPresentation],
            oldLeadingCount: Int,
            insertedMessageIDs: Set<MessageID>,
            removedMessageIDs: Set<MessageID>
        ) -> JournalIdentityChanges? {
            let currentIdentities = items
                .dropFirst(oldLeadingCount)
                .compactMap { $0.messageRow?.identity }
            let finalIdentities = newRows.map(\.identity)
            let currentSet = Set(currentIdentities)
            let finalSet = Set(finalIdentities)
            guard currentIdentities.count == messageIDs.count,
                  currentSet.count == currentIdentities.count,
                  finalSet.count == finalIdentities.count
            else {
                performanceFallbackReason = "journal-duplicate-message-identity"
                return nil
            }
            let finalMessageIDs = newRows.map(\.id)
            let removals = currentIdentities.indices.filter {
                !finalSet.contains(currentIdentities[$0])
            }
            guard removals.allSatisfy({ removedMessageIDs.contains(messageIDs[$0]) }) else {
                performanceFallbackReason = "journal-remove-identity"
                return nil
            }
            let insertions = finalIdentities.indices.filter {
                !currentSet.contains(finalIdentities[$0])
            }
            guard insertions.allSatisfy({ insertedMessageIDs.contains(finalMessageIDs[$0]) }) else {
                performanceFallbackReason = "journal-insert-identity"
                return nil
            }
            var applied = currentIdentities
            for index in removals.reversed() { applied.remove(at: index) }
            for index in insertions { applied.insert(finalIdentities[index], at: index) }
            guard applied == finalIdentities else {
                performanceFallbackReason = "journal-applied-identity"
                return nil
            }
            return JournalIdentityChanges(
                removals: removals,
                insertions: insertions,
                finalMessageIDs: finalMessageIDs
            )
        }

        func applyJournalMutation(
            to newParent: NativeMessageTimelineView,
            rows newRows: [MessageRowPresentation],
            plan: JournalMutationPlan,
            width: CGFloat
        ) {
            let leadingItems = plan.leadingItems
            let oldLeadingCount = plan.oldLeadingCount
            let changedMessageIDs = plan.changedMessageIDs
            let removalRowIndexes = plan.identityChanges.removals
            let insertionRowIndexes = plan.identityChanges.insertions
            let finalMessageIDs = plan.identityChanges.finalMessageIDs
            for index in leadingItems.indices where items[index] != leadingItems[index] {
                replaceItem(at: index, with: leadingItems[index], width: width)
            }
            let previousFirstMessageID = messageIDs.first
            for rowIndex in removalRowIndexes.reversed() {
                let itemIndex = oldLeadingCount + rowIndex
                items.remove(at: itemIndex)
                layouts.remove(at: itemIndex)
                rowHeights.remove(at: itemIndex)
            }
            for rowIndex in insertionRowIndexes {
                let item = messageItem(newRows[rowIndex], from: newParent)
                let insertedLayout = layout(for: item, width: width)
                let itemIndex = oldLeadingCount + rowIndex
                items.insert(item, at: itemIndex)
                layouts.insert(insertedLayout, at: itemIndex)
                rowHeights.insert(insertedLayout.height, at: itemIndex)
            }
            storage.invalidateItemIndex()
            for rowIndex in newRows.indices
            where changedMessageIDs.contains(newRows[rowIndex].id) {
                refreshItemPresentation(
                    at: oldLeadingCount + rowIndex,
                    with: messageItem(newRows[rowIndex], from: newParent),
                    width: width
                )
            }
            didPrependItems = finalMessageIDs.first.map {
                previousFirstMessageID != $0 && insertionRowIndexes.contains(0)
            } ?? false
            messageIDs = finalMessageIDs
            didMutateItems = true
            requiresVisibleRedraw = true
            requiresAnchorRestore = true
            requiresFullOriginRebuild = true
            performanceUpdatePath = "bounded-journal-merge"
        }
}
