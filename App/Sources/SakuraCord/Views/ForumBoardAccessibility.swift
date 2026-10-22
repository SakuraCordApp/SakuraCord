import AppKit
import SakuraCordModels

extension ForumBoardView {
    /// Mirrors realized posts as invisible proxy views, so VoiceOver can find,
    /// read and activate cards that are only painted into layers.
    func updateAccessibilityChildren() {
        guard let layoutState else { return }
        var live: [ForumBoardItem.Identifier: ForumBoardAccessibilityProxyView] = [:]
        var ordered: [ForumBoardAccessibilityProxyView] = []
        for entry in layoutState.entries(intersecting: realizationRect(for: visibleRect)) {
            let id = entry.item.id
            let item = entry.item
            switch item {
            case let .post(input):
                guard let presentation = presentations[input.id] else { continue }
                let postID = input.id
                let proxy = accessibilityProxies.removeValue(forKey: id) ?? makeProxy(
                    press: { [weak self] in self?.activate(item, at: nil) ?? false },
                    showMenu: { [weak self] in self?.accessibilityShowMenu(postID) ?? false }
                )
                proxy.frame = entry.frame
                let renderer = excerptRenderers[postID]
                var revealSpoiler: (@MainActor () -> Bool)?
                if let renderer, let location = renderer.hiddenSpoilerRanges.first?.location {
                    revealSpoiler = { [weak renderer] in
                        renderer?.revealSpoiler(at: location)
                        return renderer != nil
                    }
                }
                proxy.update(
                    presentation: presentation,
                    excerpt: renderer?.accessibilityText,
                    toggleReaction: { [weak self] in self?.toggleReaction(on: postID) ?? false },
                    revealSpoiler: revealSpoiler
                )
                live[id] = proxy
                ordered.append(proxy)
            case .paginationStatus:
                guard let message = snapshot?.paginationError else { continue }
                let proxy = accessibilityProxies.removeValue(forKey: id) ?? makeProxy(
                    press: { [weak self] in self?.activate(item, at: nil) ?? false },
                    showMenu: { false }
                )
                proxy.frame = entry.frame
                proxy.updateRetry(message: message)
                live[id] = proxy
                ordered.append(proxy)
            case .placeholder, .olderPostsHeader:
                continue
            }
        }
        for proxy in accessibilityProxies.values { proxy.removeFromSuperview() }
        accessibilityProxies = live
        // VoiceOver reads proxies in subview order; a reused proxy keeps its
        // old place, so a reordered board reorders them to match.
        let current = subviews.compactMap { $0 as? ForumBoardAccessibilityProxyView }
        if !current.elementsEqual(ordered, by: ===) {
            subviews = subviews.filter { !($0 is ForumBoardAccessibilityProxyView) } + ordered
        }
    }

    private func makeProxy(
        press: @escaping @MainActor @Sendable () -> Bool,
        showMenu: @escaping @MainActor @Sendable () -> Bool
    ) -> ForumBoardAccessibilityProxyView {
        let proxy = ForumBoardAccessibilityProxyView(press: press, showMenu: showMenu)
        addSubview(proxy)
        return proxy
    }

    private func accessibilityShowMenu(_ postID: ChannelID) -> Bool {
        guard let model, let channel, let post = postsByID[postID], let entry = layoutState?.entry(for: .post(postID)) else { return false }
        let menu = contextMenu(for: post, model: model, channel: channel)
        menu.popUp(positioning: nil, at: CGPoint(x: entry.frame.minX + 20, y: entry.frame.minY + 20), in: self)
        return true
    }
}

/// One post as VoiceOver sees it: a button with its unread state, excerpt,
/// counts and actions, laid over the painted card. It never takes clicks.
final class ForumBoardAccessibilityProxyView: NSView {
    nonisolated let press: @MainActor @Sendable () -> Bool
    nonisolated let showMenu: @MainActor @Sendable () -> Bool

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    init(press: @escaping @MainActor @Sendable () -> Bool, showMenu: @escaping @MainActor @Sendable () -> Bool) {
        self.press = press
        self.showMenu = showMenu
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func isAccessibilityElement() -> Bool { true }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func draw(_: NSRect) {}

    func update(
        presentation: ForumCardPresentation,
        excerpt: String?,
        toggleReaction: @escaping @MainActor () -> Bool,
        revealSpoiler: (@MainActor () -> Bool)?
    ) {
        setAccessibilityRole(.button)
        setAccessibilityHelp("Opens this post as a thread")
        setAccessibilityLabel(presentation.accessibilityLabel)
        var value = [presentation.isEmphasized ? "Unread" : "Read"]
        if let excerpt, !excerpt.isEmpty { value.append(excerpt) }
        if let attachment = presentation.thumbnail?.accessibilityDescription { value.append(attachment) }
        if let author = presentation.galleryAuthor { value.append("Posted by \(author.name)") }
        if let reaction = presentation.reaction {
            value.append(MessageReactionPresentation.accessibilityLabel(for: reaction.reaction))
        }
        value.append("Posted \(presentation.createdAt.formatted(date: .abbreviated, time: .shortened))")
        value.append(presentation.messageCountAccessibilityText)
        value.append("Last activity \(presentation.lastActivityAt.formatted(date: .abbreviated, time: .shortened))")
        setAccessibilityValue(value.joined(separator: ", "))
        setAccessibilitySelected(presentation.isSelected)
        var actions: [NSAccessibilityCustomAction] = []
        if let reaction = presentation.reaction, !reaction.isDisabled {
            let verb = reaction.reaction.didCurrentUserReact ? "Remove" : "Add"
            actions.append(NSAccessibilityCustomAction(name: "\(verb) Reaction \(reaction.reaction.emojiReference.name)") {
                toggleReaction()
            })
        }
        if let revealSpoiler {
            actions.append(NSAccessibilityCustomAction(name: "Reveal spoiler") { revealSpoiler() })
        }
        setAccessibilityCustomActions(actions)
    }

    /// The failed-page notice: its press retries.
    func updateRetry(message: String) {
        setAccessibilityRole(.button)
        setAccessibilityLabel("Couldn’t load more posts. Try Again")
        setAccessibilityValue(message)
        setAccessibilityHelp("Loads the next page of posts again")
        setAccessibilityCustomActions([])
    }

    nonisolated override func accessibilityPerformPress() -> Bool {
        let action = press
        return MainActor.assumeIsolated { action() }
    }

    nonisolated override func accessibilityPerformShowMenu() -> Bool {
        let action = showMenu
        return MainActor.assumeIsolated { action() }
    }
}
