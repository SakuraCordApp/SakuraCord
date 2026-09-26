import AppKit
import CoreText
import OSLog
import SakuraCordModels
import SwiftUI

@MainActor
extension NativeMemberListCanvasView {
    func updatePresentation(
        customEmojiURLsByID: CustomEmojiImageURLs = [:],
        profilePresentation: ProfilePresentationState?,
        isProfilePresented: Bool,
        dismissProfile: @escaping () -> Void
    ) {
        let previousSelectedMemberID = selectedMemberID
        let previousCustomEmojiURLsByID = self.customEmojiURLsByID
        self.customEmojiURLsByID = customEmojiURLsByID
        self.profilePresentation = profilePresentation
        self.isProfilePresented = isProfilePresented
        self.dismissProfile = dismissProfile
        selectedMemberID = isProfilePresented
            ? profilePresentation?.member.id
            : nil
        if previousCustomEmojiURLsByID != customEmojiURLsByID {
            needsDisplay = true
        }
        for index in selectionInvalidationIndexes(
            previous: previousSelectedMemberID,
            current: selectedMemberID
        ) {
            setNeedsDisplay(itemRect(at: index))
        }
        updateVisibleOverlaysAndPrewarming(
            force: previousCustomEmojiURLsByID != customEmojiURLsByID
        )
    }

    func modalInputDidChange() {
        setInteractionsBlocked(!WindowModalCoordinator.allowsInput(for: self))
    }

    func setInteractionsBlocked(_ blocked: Bool) {
        guard interactionsBlocked != blocked else { return }
        interactionsBlocked = blocked
        if blocked {
            if let old = hoveredIndex {
                hoveredIndex = nil
                setNeedsDisplay(itemRect(at: old))
            }
            removeRowOverlay()
            profilePopoverCoordinator.close()
        }
        updateTrackingAreas()
        window?.invalidateCursorRects(for: self)
        updateVisibleOverlaysAndPrewarming()
    }

    @discardableResult
    func updateDocumentIfNeeded(
        sections: [MemberSection],
        previousItems: [Item]? = nil
    ) -> Bool {
        guard sections != presentedSections else { return false }
        guard let document = Self.prepareDocument(
            sections: sections,
            presentation: presentation,
            reusing: preparationSnapshot()
        ) else {
            return false
        }
        return applyPreparedDocument(document, previousItems: previousItems)
    }

    @discardableResult
    func applyPreparedDocument(
        _ document: PreparedDocument,
        previousItems suppliedPreviousItems: [Item]? = nil
    ) -> Bool {
        guard document.sections != presentedSections
            || document.presentation != presentation
            || document.stableLayoutChangedIndexes?.isEmpty == false
            || document.preparedText.contains(where: { preparedText[$0.key]?.nameFont != $0.value.nameFont })
        else { return false }
        let previousItems = suppliedPreviousItems ?? items
        presentation = document.presentation
        presentedSections = document.sections
        items = document.items
        itemIndexesByID = document.itemIndexesByID
        if let hoveredIndex,
           !items.indices.contains(hoveredIndex) ||
           !previousItems.indices.contains(hoveredIndex) ||
           items[hoveredIndex].id != previousItems[hoveredIndex].id
        {
            self.hoveredIndex = nil
        }
        origins = document.origins
        contentHeight = document.contentHeight
        invalidateIntrinsicContentSize()
        preparedText = document.preparedText
        loadedItemIndexes = document.loadedItemIndexes
        let placeholderStateChanged = hasLoadingPlaceholders
            != document.hasLoadingPlaceholders
        hasLoadingPlaceholders = document.hasLoadingPlaceholders
        if placeholderStateChanged {
            if hasLoadingPlaceholders {
                AppPerformanceSignposts.signposter.emitEvent(
                    "MemberListNativePlaceholderRenderingStarted"
                )
            } else {
                AppPerformanceSignposts.signposter.emitEvent(
                    "MemberListNativePlaceholderRenderingEnded"
                )
            }
        }
        reconcilePlaceholderShimmer()
        if let changedIndexes = document.stableLayoutChangedIndexes {
            for index in changedIndexes where items.indices.contains(index) {
                setNeedsDisplay(itemRect(at: index))
            }
        } else {
            // Structural section changes can shift every subsequent row. Asking
            // AppKit to invalidate the document is constant-time and drawing is
            // still clipped to exposed regions. Comparing every row here merely
            // moves an O(member count) pass back onto the main thread.
            needsDisplay = true
        }
        if let changedIndexes = document.stableLayoutChangedIndexes {
            let visible = itemRange(
                intersecting: enclosingScrollView?.documentVisibleRect ?? .zero
            )
            let prewarm = max(
                0,
                visible.lowerBound - NativeMemberListMetrics.prewarmItemCount
            ) ..< min(
                items.count,
                visible.upperBound + NativeMemberListMetrics.prewarmItemCount
            )
            let changesPrewarmedContent = changedIndexes.contains {
                prewarm.contains($0)
            }
            updateVisibleOverlaysAndPrewarming(force: changesPrewarmedContent)
        } else {
            reconciledVisibleRange = nil
            updateVisibleOverlaysAndPrewarming(force: true)
        }
        return true
    }

    func selectionInvalidationIndexes(
        previous: UserID?,
        current: UserID?
    ) -> [Int] {
        guard previous != current else { return [] }
        var indexes: [Int] = []
        if let previous,
           let index = itemIndexesByID[.member(previous)]
        {
            indexes.append(index)
        }
        if let current,
           let index = itemIndexesByID[.member(current)],
           !indexes.contains(index)
        {
            indexes.append(index)
        }
        return indexes.sorted()
    }

    nonisolated static func prepareDocument(
        sections: [MemberSection],
        presentation: NativeMemberListPresentation = .init(),
        reusing preparationSnapshot: PreparationSnapshot? = nil,
        cancelsCooperatively: Bool = false
    ) -> PreparedDocument? {
        if let preparationSnapshot,
           preparationSnapshot.presentation == presentation
        {
            let stableDocument = AppPerformanceSignposts.measureSync(
                "MemberListStableLayoutPreparation"
            ) {
                prepareStableLayoutDocument(
                    sections: sections,
                    presentation: presentation,
                    reusing: preparationSnapshot,
                    cancelsCooperatively: cancelsCooperatively
                )
            }
            if let stableDocument { return stableDocument }
        }
        guard let items = makeItems(
            sections: sections,
            cancelsCooperatively: cancelsCooperatively
        ) else { return nil }
        var itemIndexesByID: [ItemID: Int] = [:]
        itemIndexesByID.reserveCapacity(items.count)
        var origins: [CGFloat] = []
        origins.reserveCapacity(items.count)
        var cursorY = NativeMemberListMetrics.verticalInset
        for index in items.indices {
            if cancelsCooperatively,
               index.isMultiple(of: 128),
               Task.isCancelled
            {
                return nil
            }
            itemIndexesByID[items[index].id] = index
            origins.append(cursorY)
            cursorY += items[index].height
        }
        let preparedText = AppPerformanceSignposts.measureSync(
            "MemberListTextPreparation"
        ) {
            prepareText(
                for: items,
                presentation: presentation,
                reusing: preparationSnapshot,
                cancelsCooperatively: cancelsCooperatively
            )
        }
        guard let preparedText else { return nil }
        return PreparedDocument(
            presentation: presentation,
            sections: sections,
            items: items,
            itemIndexesByID: itemIndexesByID,
            origins: origins,
            contentHeight: cursorY + NativeMemberListMetrics.verticalInset,
            preparedText: preparedText,
            loadedItemIndexes: items.indices.filter {
                if case .member = items[$0] { true } else { false }
            },
            hasLoadingPlaceholders: items.contains {
                switch $0 {
                case .header(let header): header.isLoadingSkeleton
                case .placeholder: true
                case .member: false
                }
            },
            stableLayoutChangedIndexes: nil
        )
    }

    private nonisolated static func prepareStableLayoutDocument(
        sections: [MemberSection],
        presentation: NativeMemberListPresentation,
        reusing snapshot: PreparationSnapshot,
        cancelsCooperatively: Bool
    ) -> PreparedDocument? {
        guard let projection = stableLayoutProjection(
            sections: sections,
            snapshot: snapshot,
            cancelsCooperatively: cancelsCooperatively
        ), let replacements = stableLayoutReplacements(
            sections: sections,
            snapshot: snapshot,
            projection: projection,
            cancelsCooperatively: cancelsCooperatively
        ) else { return nil }
        let changedIndexes = replacements.keys.sorted()
        guard let replacementText = prepareText(
            for: changedIndexes.compactMap { replacements[$0] },
            presentation: presentation,
            reusing: nil,
            cancelsCooperatively: cancelsCooperatively
        ) else { return nil }
        return applyingStableLayoutReplacements(
            replacements,
            replacementText: replacementText,
            changedIndexes: changedIndexes,
            sections: sections,
            snapshot: snapshot,
            loadedItemIndexes: projection.desiredMembersByItemIndex.keys.sorted()
        )
    }

    private nonisolated static func stableLayoutProjection(
        sections: [MemberSection],
        snapshot: PreparationSnapshot,
        cancelsCooperatively: Bool
    ) -> StableLayoutProjection? {
        guard hasStableSectionLayout(sections, snapshot: snapshot) else {
            return nil
        }
        var desiredMembersByItemIndex: [Int: Member] = [:]
        desiredMembersByItemIndex.reserveCapacity(
            sections.reduce(0) { $0 + min($1.members.count, $1.totalCount) }
        )
        var headerIndexes: [Int] = []
        headerIndexes.reserveCapacity(sections.count)
        var itemCursor = 0
        for (sectionOffset, section) in sections.enumerated() {
            if cancelsCooperatively,
               sectionOffset.isMultiple(of: 8),
               Task.isCancelled
            {
                return nil
            }
            guard snapshot.items.indices.contains(itemCursor),
                  let gatewayStartIndex = section.gatewayStartIndex
            else { return nil }
            headerIndexes.append(itemCursor)
            guard section.totalCount > 0 else {
                itemCursor += 1
                continue
            }
            let gatewayRange = (gatewayStartIndex + 1)
                ... (gatewayStartIndex + section.totalCount)
            var indexedGatewayIndexes: Set<Int> = []
            var inferredMembers: [Member] = []
            for member in section.members.prefix(max(0, section.totalCount)) {
                guard let gatewayIndex = member.memberListIndex,
                      gatewayRange.contains(gatewayIndex)
                else {
                    inferredMembers.append(member)
                    continue
                }
                guard indexedGatewayIndexes.insert(gatewayIndex).inserted else {
                    continue
                }
                let itemIndex = itemCursor + 1
                    + gatewayIndex - gatewayRange.lowerBound
                desiredMembersByItemIndex[itemIndex] = member
            }
            var inferredGatewayIndex = gatewayRange.lowerBound
            for member in inferredMembers {
                while inferredGatewayIndex <= gatewayRange.upperBound,
                      indexedGatewayIndexes.contains(inferredGatewayIndex)
                {
                    if cancelsCooperatively,
                       inferredGatewayIndex.isMultiple(of: 128),
                       Task.isCancelled
                    {
                        return nil
                    }
                    inferredGatewayIndex += 1
                }
                guard inferredGatewayIndex <= gatewayRange.upperBound else {
                    break
                }
                let itemIndex = itemCursor + 1
                    + inferredGatewayIndex - gatewayRange.lowerBound
                desiredMembersByItemIndex[itemIndex] = member
                inferredGatewayIndex += 1
            }
            itemCursor += section.totalCount + 1
        }
        guard itemCursor == snapshot.items.count else {
            AppPerformanceSignposts.signposter.emitEvent(
                "MemberListStableLayoutItemCountMismatch"
            )
            return nil
        }
        return StableLayoutProjection(
            headerIndexes: headerIndexes,
            desiredMembersByItemIndex: desiredMembersByItemIndex
        )
    }

    private nonisolated static func hasStableSectionLayout(
        _ sections: [MemberSection],
        snapshot: PreparationSnapshot
    ) -> Bool {
        guard sections.count == snapshot.sections.count else {
            AppPerformanceSignposts.signposter.emitEvent(
                "MemberListStableLayoutSectionCountMismatch"
            )
            return false
        }
        for (current, previous) in zip(sections, snapshot.sections) {
            guard current.id == previous.id else {
                AppPerformanceSignposts.signposter.emitEvent(
                    "MemberListStableLayoutSectionIdentityMismatch"
                )
                return false
            }
            guard current.totalCount == previous.totalCount else {
                AppPerformanceSignposts.signposter.emitEvent(
                    "MemberListStableLayoutSectionTotalMismatch"
                )
                return false
            }
            guard current.gatewayStartIndex == previous.gatewayStartIndex else {
                AppPerformanceSignposts.signposter.emitEvent(
                    "MemberListStableLayoutGatewayStartMismatch"
                )
                return false
            }
        }
        return true
    }

    private nonisolated static func stableLayoutReplacements(
        sections: [MemberSection],
        snapshot: PreparationSnapshot,
        projection: StableLayoutProjection,
        cancelsCooperatively: Bool
    ) -> [Int: Item]? {
        var candidateIndexes = Set(snapshot.loadedItemIndexes)
        candidateIndexes.formUnion(projection.desiredMembersByItemIndex.keys)
        candidateIndexes.formUnion(projection.headerIndexes)
        let sortedCandidates = candidateIndexes.sorted()
        var replacementItemsByIndex: [Int: Item] = [:]
        replacementItemsByIndex.reserveCapacity(sortedCandidates.count)
        var sectionOffset = 0
        var nextHeaderOffset = 0
        for index in sortedCandidates {
            if cancelsCooperatively,
               index.isMultiple(of: 128),
               Task.isCancelled
            {
                return nil
            }
            let desiredItem: Item
            if nextHeaderOffset < projection.headerIndexes.count,
               projection.headerIndexes[nextHeaderOffset] == index
            {
                desiredItem = .header(Header(sections[nextHeaderOffset]))
                nextHeaderOffset += 1
            } else if let member = projection.desiredMembersByItemIndex[index] {
                desiredItem = .member(
                    member,
                    gatewayIndex: member.memberListIndex
                )
            } else {
                while sectionOffset + 1 < projection.headerIndexes.count,
                      index > projection.headerIndexes[sectionOffset + 1]
                {
                    sectionOffset += 1
                }
                guard let gatewayStartIndex = sections[sectionOffset]
                    .gatewayStartIndex
                else { return nil }
                let gatewayIndex = gatewayStartIndex
                    + index - projection.headerIndexes[sectionOffset]
                desiredItem = .placeholder(gatewayIndex: gatewayIndex)
            }
            let fontChanged: Bool
            if case let .member(member, _) = desiredItem {
                fontChanged = snapshot.preparedText[desiredItem.id]?.nameFont != nameFont(for: member)
            } else { fontChanged = false }
            guard snapshot.items[index] != desiredItem || fontChanged else { continue }
            replacementItemsByIndex[index] = desiredItem
        }
        return replacementItemsByIndex
    }

    private nonisolated static func applyingStableLayoutReplacements(
        _ replacements: [Int: Item],
        replacementText: [ItemID: PreparedText],
        changedIndexes: [Int],
        sections: [MemberSection],
        snapshot: PreparationSnapshot,
        loadedItemIndexes: [Int]
    ) -> PreparedDocument {
        var items = snapshot.items
        var itemIndexesByID = snapshot.itemIndexesByID
        var preparedText = snapshot.preparedText
        for index in changedIndexes {
            guard let replacement = replacements[index] else {
                continue
            }
            let previousID = items[index].id
            if itemIndexesByID[previousID] == index {
                itemIndexesByID[previousID] = nil
                preparedText[previousID] = nil
            }
            items[index] = replacement
            itemIndexesByID[replacement.id] = index
            if let prepared = replacementText[replacement.id] {
                preparedText[replacement.id] = prepared
            }
        }
        return PreparedDocument(
            presentation: snapshot.presentation,
            sections: sections,
            items: items,
            itemIndexesByID: itemIndexesByID,
            origins: snapshot.origins,
            contentHeight: snapshot.contentHeight,
            preparedText: preparedText,
            loadedItemIndexes: loadedItemIndexes,
            hasLoadingPlaceholders: items.contains {
                switch $0 {
                case .header(let header): header.isLoadingSkeleton
                case .placeholder: true
                case .member: false
                }
            },
            stableLayoutChangedIndexes: changedIndexes
        )
    }

    private nonisolated static func makeItems(
        sections: [MemberSection],
        cancelsCooperatively: Bool
    ) -> [Item]? {
        var result: [Item] = []
        result.reserveCapacity(sections.reduce(0) { $0 + $1.totalCount + 1 })
        for (sectionOffset, section) in sections.enumerated() {
            if cancelsCooperatively,
               sectionOffset.isMultiple(of: 8),
               Task.isCancelled
            {
                return nil
            }
            result.append(.header(Header(section)))
            let visibleMembers = section.members.prefix(max(0, section.totalCount))
            guard let sectionStart = section.gatewayStartIndex else {
                result.append(contentsOf: visibleMembers.map { member in
                    .member(member, gatewayIndex: member.memberListIndex)
                })
                continue
            }
            guard section.totalCount > 0 else { continue }

            let gatewayRange = (sectionStart + 1) ... (sectionStart + section.totalCount)
            var indexedMembers: [Int: Member] = [:]
            var inferredMembers: [Member] = []
            inferredMembers.reserveCapacity(visibleMembers.count)
            for member in visibleMembers {
                if let index = member.memberListIndex, gatewayRange.contains(index) {
                    indexedMembers[index] = indexedMembers[index] ?? member
                } else {
                    inferredMembers.append(member)
                }
            }
            var inferredIndex = inferredMembers.startIndex
            for gatewayIndex in gatewayRange {
                if cancelsCooperatively,
                   gatewayIndex.isMultiple(of: 128),
                   Task.isCancelled
                {
                    return nil
                }
                if let member = indexedMembers[gatewayIndex] {
                    result.append(.member(member, gatewayIndex: gatewayIndex))
                } else if inferredIndex < inferredMembers.endIndex {
                    result.append(.member(
                        inferredMembers[inferredIndex], gatewayIndex: gatewayIndex
                    ))
                    inferredMembers.formIndex(after: &inferredIndex)
                } else {
                    result.append(.placeholder(gatewayIndex: gatewayIndex))
                }
            }
        }
        return result
    }

    func preparationSnapshot() -> PreparationSnapshot {
        PreparationSnapshot(
            presentation: presentation,
            sections: presentedSections,
            items: items,
            itemIndexesByID: itemIndexesByID,
            origins: origins,
            contentHeight: contentHeight,
            preparedText: preparedText,
            loadedItemIndexes: loadedItemIndexes
        )
    }

    private nonisolated static func nameFont(for member: Member) -> NSFont {
        ProfileNameFontCache.font(id: member.user.displayNameStyle?.fontID, fallback: .systemFont(
            ofSize: InterfaceTypographyMetrics.interfaceTextSize, weight: .semibold
        ))
    }

    private nonisolated static func prepareText(
        for items: [Item],
        presentation: NativeMemberListPresentation,
        reusing preparationSnapshot: PreparationSnapshot?,
        cancelsCooperatively: Bool
    ) -> [ItemID: PreparedText]? {
        let activityFont = NSFont.systemFont(
            ofSize: max(10, InterfaceTypographyMetrics.interfaceTextSize - 1)
        )
        let appearance = NSAppearance(named: presentation.isDark ? .darkAqua : .aqua)
            ?? NSAppearance.currentDrawing()
        var labelColor = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance {
            labelColor = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
        }
        var preparedText: [ItemID: PreparedText] = [:]
        preparedText.reserveCapacity(min(
            items.count,
            (preparationSnapshot?.preparedText.count ?? 0) + 128
        ))
        for index in items.indices {
            if cancelsCooperatively,
               index.isMultiple(of: 16),
               Task.isCancelled
            {
                return nil
            }
            let item = items[index]
            guard case .member(let member, _) = item else { continue }
            let nameFont = nameFont(for: member)
            if preparationSnapshot?.presentation == presentation,
               let previousIndex = preparationSnapshot?.itemIndexesByID[item.id],
               let previousItems = preparationSnapshot?.items,
               previousItems.indices.contains(previousIndex),
               previousItems[previousIndex] == item,
               let existing = preparationSnapshot?.preparedText[item.id],
               existing.nameFont == nameFont
            {
                preparedText[item.id] = existing
                continue
            }
            let nameColor = presentation.roleColorDisplay == .inNames
                ? MessageAuthorPresentation.topRoleColor(in: member.roles)
                    .map(Self.color(hex:)) ?? labelColor
                : labelColor
            let alpha: CGFloat = !member.isListedOnline ? 0.55 : 1
            let name = Self.line(
                member.user.displayName,
                font: nameFont,
                color: nameColor.withAlphaComponent(alpha)
            )
            let activity = member.memberListActivityText.flatMap { text -> CTLine? in
                guard !text.isEmpty else { return nil }
                return NativeMemberActivityPresentation.line(
                    text,
                    font: activityFont,
                    color: Self.memberActivityColor.withAlphaComponent(alpha),
                    showsMusicIcon: member.isListeningToMusic,
                    showsMusicSeparator: member.memberListShowsMusicSeparator
                )
            }
            let activityTruncationToken = activity.map { _ in
                Self.line(
                    "…",
                    font: activityFont,
                    color: Self.memberActivityColor.withAlphaComponent(alpha)
                )
            }
            preparedText[item.id] = PreparedText(
                nameFont: nameFont,
                name: name,
                nameTruncationToken: Self.line(
                    "…",
                    font: nameFont,
                    color: nameColor.withAlphaComponent(alpha)
                ),
                nameWidth: CGFloat(CTLineGetTypographicBounds(name, nil, nil, nil)),
                activity: activity,
                activityTruncationToken: activityTruncationToken,
                activityWidth: activity.map {
                    CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil))
                } ?? 0
            )
        }
        return preparedText
    }

}
