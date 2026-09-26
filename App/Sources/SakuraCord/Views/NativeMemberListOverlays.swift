import AppKit
import CoreText
import OSLog
import SakuraCordModels
import SwiftUI

@MainActor
extension NativeMemberListCanvasView {
    func setScrolling(_ scrolling: Bool) {
        guard isScrolling != scrolling else { return }
        isScrolling = scrolling
        if scrolling {
            hoveredIndex = nil
            removeRowOverlay()
        } else if !interactionsBlocked, let window {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            hoveredIndex = index(at: point)
        }
        updateVisibleOverlaysAndPrewarming()
    }

    @discardableResult
    func updateVisibleOverlaysAndPrewarming(
        force: Bool = false,
        reconcileInteraction: Bool = true
    ) -> Bool {
        guard let scrollView = enclosingScrollView else { return false }
        let visible = itemRange(intersecting: scrollView.documentVisibleRect)
        let viewportChanged = visible != reconciledVisibleRange
            || bounds.width != reconciledViewportWidth
        if reconcileInteraction || viewportChanged || force {
            installRowOverlayIfNeeded()
            installAvatarOverlays(in: visible)
        }
        guard force || viewportChanged else { return false }
        reconciledVisibleRange = visible
        reconciledViewportWidth = bounds.width
        let prewarmLower = max(0, visible.lowerBound - NativeMemberListMetrics.prewarmItemCount)
        let prewarmUpper = min(items.count, visible.upperBound + NativeMemberListMetrics.prewarmItemCount)
        let prewarmRange = prewarmLower ..< prewarmUpper
        installActivityEmojiOverlays(in: visible)
        installAccessibilityRows(in: visible)
        prewarmImages(in: prewarmRange, visible: visible)
        return true
    }

    func reconcilePlaceholderShimmer() {
        placeholderShimmerTask?.cancel()
        placeholderShimmerTask = nil
        guard hasLoadingPlaceholders,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else { return }
        placeholderShimmerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(
                        for: .seconds(
                            SkeletonShimmerStyle.minimumFrameInterval
                        )
                    )
                } catch {
                    return
                }
                guard let self, self.hasLoadingPlaceholders else { return }
                if let rect = self.visiblePlaceholderInvalidationRect() {
                    self.setNeedsDisplay(rect)
                }
            }
        }
    }

    private func visiblePlaceholderInvalidationRect() -> CGRect? {
        guard let visibleRect = enclosingScrollView?.documentVisibleRect
        else { return nil }
        let range = itemRange(intersecting: visibleRect)
        var result: CGRect?
        for index in range {
            let placeholderRect: CGRect? = switch items[index] {
            case .header(let header) where header.isLoadingSkeleton:
                itemRect(at: index)
            case .placeholder:
                paintedRowRect(at: index)
            default:
                nil
            }
            guard let placeholderRect else { continue }
            result = result.map { $0.union(placeholderRect) }
                ?? placeholderRect
        }
        return result
    }

    func installAvatarOverlays(in range: Range<Int>) {
        let visibleMembers: [AvatarOverlayPresentation] = range
            .compactMap { index in
                guard case .member(let member, _) = items[index],
                      Self.requiresAvatarOverlay(for: member)
                else {
                    return nil
                }
                return AvatarOverlayPresentation(
                    id: items[index].id,
                    member: member,
                    index: index
                )
            }
        let visibleIDs = Set(visibleMembers.map(\.id))
        var reusableHosts: [NSHostingView<AnyView>] = []
        for id in Array(avatarOverlays.keys) where !visibleIDs.contains(id) {
            guard let host = avatarOverlays.removeValue(forKey: id) else {
                continue
            }
            avatarOverlayConfigurations[id] = nil
            reusableHosts.append(host)
        }

        for presentation in visibleMembers {
            let id = presentation.id
            let member = presentation.member
            let index = presentation.index
            let host = avatarOverlays[id] ?? {
                let value = reusableHosts.popLast()
                    ?? NSHostingView(rootView: AnyView(EmptyView()))
                value.sizingOptions = []
                value.wantsLayer = true
                if value.superview == nil {
                    addSubview(value)
                }
                avatarOverlays[id] = value
                return value
            }()
            let configuration = AvatarOverlayConfiguration(
                member: member,
                isHovered: hoveredIndex == index && !isScrolling && !interactionsBlocked
                    && WindowModalCoordinator.allowsInput(for: self)
            )
            if avatarOverlayConfigurations[id] != configuration {
                host.rootView = AnyView(
                    MemberAvatar(member: member, isHovered: configuration.isHovered)
                        .opacity(member.isListedOnline ? 1 : 0.55)
                        .allowsHitTesting(false)
                )
                avatarOverlayConfigurations[id] = configuration
            }
            host.frame = CGRect(
                x: NativeMemberListMetrics.horizontalInset + 4,
                y: origins[index] + 1
                    + (NativeMemberListMetrics.paintedRowHeight
                        - NativeMemberListMetrics.avatarContainerSize) / 2,
                width: NativeMemberListMetrics.avatarContainerSize,
                height: NativeMemberListMetrics.avatarContainerSize
            )
            host.layer?.zPosition = 11
            host.setAccessibilityHidden(true)
        }
        for host in reusableHosts {
            host.removeFromSuperview()
        }
    }

    func removeAvatarOverlays() {
        for host in avatarOverlays.values { host.removeFromSuperview() }
        avatarOverlays.removeAll(keepingCapacity: true)
        avatarOverlayConfigurations.removeAll(keepingCapacity: true)
    }

    func installActivityEmojiOverlays(in range: Range<Int>) {
        var visibleOverlays: [ActivityEmojiOverlayPresentation] = []
        var overlayCount = 0
        for index in range {
            guard overlayCount < NativeMemberListMetrics.maximumVisibleAnimatedEmojiCount,
                  case .member(let member, _) = items[index],
                  let prepared = preparedText[items[index].id],
                  let activity = prepared.activity,
                  let truncationToken = prepared.activityTruncationToken
            else { continue }
            let row = paintedRowRect(at: index)
            let textX = row.minX + 4 + NativeMemberListMetrics.avatarContainerSize + 8
            let visibleActivity = Self.truncatedLine(
                activity,
                token: truncationToken,
                maximumWidth: max(0, row.maxX - textX - 4)
            )
            let origin = CGPoint(x: textX, y: row.minY + 24)
            for (ordinal, region) in NativeMemberActivityPresentation.emojiRegions(
                in: visibleActivity,
                origin: origin
            ).enumerated() {
                guard overlayCount < NativeMemberListMetrics.maximumVisibleAnimatedEmojiCount,
                      region.reference.isAnimated,
                      let url = activityEmojiURL(for: region.reference)
                else { continue }
                overlayCount += 1
                let id = ActivityEmojiOverlayID(
                    itemID: items[index].id,
                    ordinal: ordinal
                )
                let configuration = ActivityEmojiOverlayConfiguration(
                    url: url,
                    opacity: member.isListedOnline ? 1 : 0.55
                )
                visibleOverlays.append(ActivityEmojiOverlayPresentation(
                    id: id,
                    configuration: configuration,
                    frame: region.frame
                ))
            }
        }

        let visibleIDs = Set(visibleOverlays.map(\.id))
        var reusableHosts: [NSHostingView<AnyView>] = []
        for id in Array(activityEmojiOverlays.keys)
            where !visibleIDs.contains(id)
        {
            guard let host = activityEmojiOverlays.removeValue(forKey: id)
            else { continue }
            activityEmojiOverlayConfigurations[id] = nil
            reusableHosts.append(host)
        }

        for presentation in visibleOverlays {
            let id = presentation.id
            let configuration = presentation.configuration
            let host = activityEmojiOverlays[id] ?? {
                let value = reusableHosts.popLast()
                    ?? NSHostingView(rootView: AnyView(EmptyView()))
                value.sizingOptions = []
                value.wantsLayer = true
                if value.superview == nil {
                    addSubview(value)
                }
                activityEmojiOverlays[id] = value
                return value
            }()
            if activityEmojiOverlayConfigurations[id] != configuration {
                host.rootView = AnyView(
                    AnimatedRemoteImage(
                        url: configuration.url,
                        maximumPixelDimension: 64,
                    )
                    .opacity(configuration.opacity)
                    .allowsHitTesting(false)
                )
                activityEmojiOverlayConfigurations[id] = configuration
            }
            host.frame = presentation.frame
            host.layer?.zPosition = 11
            host.setAccessibilityHidden(true)
        }
        for host in reusableHosts {
            host.removeFromSuperview()
        }
    }

    func removeActivityEmojiOverlays() {
        for host in activityEmojiOverlays.values { host.removeFromSuperview() }
        activityEmojiOverlays.removeAll(keepingCapacity: true)
        activityEmojiOverlayConfigurations.removeAll(keepingCapacity: true)
    }

    func installAccessibilityRows(in range: Range<Int>) {
        var visibleIDs: Set<ItemID> = []
        for index in range {
            guard case .member(let member, _) = items[index] else { continue }
            let id = items[index].id
            visibleIDs.insert(id)
            let proxy = accessibilityRows[id] ?? {
                let value = NativeMemberAccessibilityProxyView()
                addSubview(value)
                accessibilityRows[id] = value
                return value
            }()
            proxy.member = member
            proxy.activation = { [weak self] member in self?.selectMember(member) }
            proxy.frame = paintedRowRect(at: index)
        }
        for (id, proxy) in accessibilityRows where !visibleIDs.contains(id) {
            proxy.removeFromSuperview()
            accessibilityRows[id] = nil
        }
        setAccessibilityChildren(range.compactMap { index in
            accessibilityRows[items[index].id]
        })
    }

    func installRowOverlayIfNeeded() {
        guard !interactionsBlocked, WindowModalCoordinator.allowsInput(for: self) else {
            removeRowOverlay()
            return
        }
        installProfileAnchorIfNeeded()
        let requestedIndex: Int? = if isScrolling {
            nil
        } else if let hoveredIndex,
                  items.indices.contains(hoveredIndex),
                  case .member = items[hoveredIndex]
        {
            hoveredIndex
        } else if let selectedMemberID {
            itemIndexesByID[.member(selectedMemberID)]
        } else {
            nil
        }
        guard let index = requestedIndex,
              case .member(let member, _) = items[index],
              enclosingScrollView?.documentVisibleRect.intersects(itemRect(at: index)) == true
        else {
            removeRowOverlay()
            return
        }
        let host = rowOverlay ?? {
            let value = NSHostingView(rootView: AnyView(EmptyView()))
            value.sizingOptions = []
            value.wantsLayer = true
            addSubview(value)
            rowOverlay = value
            return value
        }()
        let previousIndex = rowOverlayIndex
        rowOverlayIndex = index
        if let previousIndex, previousIndex != index, items.indices.contains(previousIndex) {
            setNeedsDisplay(itemRect(at: previousIndex))
        }
        setNeedsDisplay(itemRect(at: index))
        let isSelected = selectedMemberID == member.id
        host.rootView = AnyView(
            MemberRow(
                member: member,
                isSelected: isSelected,
                showsContents: false,
                select: { [weak self] in self?.selectMember(member) }
            )
        )
        host.frame = CGRect(
            x: NativeMemberListMetrics.horizontalInset,
            y: origins[index],
            width: max(0, bounds.width - NativeMemberListMetrics.horizontalInset * 2),
            height: NativeMemberListMetrics.memberRowHeight
        )
        host.layer?.zPosition = 10
        let foreground = rowForegroundOverlay ?? {
            let value = NativeMemberForegroundOverlayView()
            addSubview(value)
            rowForegroundOverlay = value
            return value
        }()
        foreground.canvas = self
        foreground.itemIndex = index
        foreground.frame = host.frame
        foreground.layer?.zPosition = 12
        foreground.needsDisplay = true
    }

    func installProfileAnchorIfNeeded() {
        guard isProfilePresented,
              let presentation = profilePresentation,
              let index = itemIndexesByID[.member(presentation.member.id)],
              enclosingScrollView?.documentVisibleRect.intersects(itemRect(at: index)) == true
        else {
            removeProfileAnchor()
            return
        }
        profileAnchorIndex = index
        profilePopoverCoordinator.update(
            anchor: profilePopoverAnchor,
            anchorSnapshot: nil,
            isPresented: true,
            configuration: .memberProfile,
            onDismiss: { [weak self] in
                self?.dismissProfile(ifCurrent: presentation.requestID)
            },
            presentationIdentity: AnyHashable(presentation.member.id),
            content: AnyView(ProfilePresentationContent(presentation: presentation, openProfile: openProfile)
                .environment(\.profileCosmeticPolicy, cosmeticPolicy))
        )
    }

    func removeProfileAnchor(immediately: Bool = false) {
        if immediately {
            profilePopoverCoordinator.close()
        } else {
            profilePopoverCoordinator.scheduleClose()
        }
        profileAnchorIndex = nil
    }

    func dismissProfile(ifCurrent requestID: UUID) {
        guard profilePresentation?.requestID == requestID else { return }
        dismissProfile()
    }

    func removeRowOverlay() {
        let previousIndex = rowOverlayIndex
        rowOverlay?.removeFromSuperview()
        rowOverlay = nil
        rowForegroundOverlay?.removeFromSuperview()
        rowForegroundOverlay = nil
        rowOverlayIndex = nil
        if let previousIndex, items.indices.contains(previousIndex) {
            setNeedsDisplay(itemRect(at: previousIndex))
        }
    }

    func prewarmImages(in range: Range<Int>, visible: Range<Int>) {
        var wanted: Set<URL> = []
        for index in range {
            guard case .member(let member, _) = items[index] else { continue }
            var requests: [(url: URL, maximumPixelDimension: Int)] = []
            if let url = member.guildAvatarURL ?? member.user.avatarURL {
                requests.append((url, 96))
            }
            if let url = member.user.avatarDecorationURL {
                requests.append((url, 96))
            }
            if let url = member.user.nameplate?.staticURL {
                requests.append((url, 512))
            }
            if let url = member.user.primaryGuild?.badgeURL {
                requests.append((url, 32))
            }
            requests.append(contentsOf: NativeMemberActivityPresentation.references(
                in: member.memberListActivityText
            ).compactMap(activityEmojiURL).map {
                (url: $0, maximumPixelDimension: 64)
            })
            wanted.formUnion(requests.map(\.url))
            let priority: MediaLoadPriority = visible.contains(index) ? .visible : .prefetch
            for request in requests {
                requestImageIfNeeded(
                    url: request.url,
                    index: index,
                    priority: priority,
                    maximumPixelDimension: request.maximumPixelDimension
                )
            }
        }
        for (url, task) in imageTasks where !wanted.contains(url) {
            task.cancel()
            imageTasks[url] = nil
            imageTaskPriorities[url] = nil
            imageTaskPixelDimensions[url] = nil
            imageRequestItemIDs[url] = nil
        }
        // The shared loader owns the bounded decoded cache. Retaining every
        // image encountered by a long member-list scroll here would defeat
        // that budget, so the canvas keeps only its visible/prewarmed window.
        for url in images.keys.filter({ !wanted.contains($0) }) {
            images[url] = nil
            imagePixelDimensions[url] = nil
        }
    }

    func requestImageIfNeeded(
        url: URL?,
        index: Int,
        priority: MediaLoadPriority,
        maximumPixelDimension: Int
    ) {
        guard let url,
              items.indices.contains(index),
              imagePixelDimensions[url, default: 0]
                < maximumPixelDimension
        else { return }
        imageRequestItemIDs[url, default: []].insert(items[index].id)
        if let task = imageTasks[url],
           imageTaskPixelDimensions[url, default: 0]
            < maximumPixelDimension
        {
            task.cancel()
            imageTasks[url] = nil
            imageTaskPriorities[url] = nil
            imageTaskPixelDimensions[url] = nil
        }
        guard imageTasks[url] == nil else {
            guard priority == .visible,
                  imageTaskPriorities[url] == .prefetch
            else { return }
            imageTaskPriorities[url] = .visible
            let pixelDimension = imageTaskPixelDimensions[url]
                ?? maximumPixelDimension
            let imageLoadPromotion = imageLoadPromotion
            Task {
                await imageLoadPromotion(url, pixelDimension)
            }
            return
        }
        imageTaskPriorities[url] = priority
        imageTaskPixelDimensions[url] = maximumPixelDimension
        imageTasks[url] = Task { [weak self] in
            let image = await SharedDecodedImageLoader.shared.image(
                for: url,
                maximumPixelDimension: maximumPixelDimension,
                priority: priority
            )
            guard !Task.isCancelled, let self else { return }
            imageTasks[url] = nil
            imageTaskPriorities[url] = nil
            imageTaskPixelDimensions[url] = nil
            let requestedItemIDs = imageRequestItemIDs.removeValue(forKey: url)
                ?? []
            guard let image else { return }
            images[url] = image
            imagePixelDimensions[url] = maximumPixelDimension
            for itemID in requestedItemIDs {
                guard let requestedIndex = itemIndexesByID[itemID] else { continue }
                setNeedsDisplay(itemRect(at: requestedIndex))
                if rowOverlayIndex == requestedIndex {
                    rowForegroundOverlay?.needsDisplay = true
                }
            }
        }
    }

    func activityEmojiURL(for reference: EmojiReference) -> URL? {
        reference.id.flatMap { customEmojiURLsByID[$0] }
            ?? reference.imageURL(size: 64)
    }

    func tearDown() {
        placeholderShimmerTask?.cancel()
        placeholderShimmerTask = nil
        for task in imageTasks.values { task.cancel() }
        imageTasks.removeAll()
        imageTaskPriorities.removeAll()
        imageTaskPixelDimensions.removeAll()
        imageRequestItemIDs.removeAll()
        imagePixelDimensions.removeAll()
        reconciledVisibleRange = nil
        reconciledViewportWidth = nil
        removeRowOverlay()
        removeProfileAnchor(immediately: true)
        for host in avatarOverlays.values { host.removeFromSuperview() }
        for host in activityEmojiOverlays.values { host.removeFromSuperview() }
        avatarOverlayConfigurations.removeAll()
        activityEmojiOverlayConfigurations.removeAll()
        for proxy in accessibilityRows.values { proxy.removeFromSuperview() }
        avatarOverlays.removeAll()
        activityEmojiOverlays.removeAll()
        accessibilityRows.removeAll()
    }

}
