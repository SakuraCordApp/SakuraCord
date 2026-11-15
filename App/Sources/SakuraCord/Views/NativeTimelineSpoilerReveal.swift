import AppKit
import MessageRendering
import SakuraCordModels

nonisolated enum NativeTimelineTextRegion: Hashable {
    case beginningTitle
    case beginningDescription
    case content
    case translation(UUID)
    case embed(embedID: String, textIndex: Int)
    case component(layoutIndex: Int, textIndex: Int)
}

nonisolated struct NativeTimelineTextSpoilerRevealState: Equatable {
    var locationsByRegion:
        [NativeTimelineTextRegion: Set<Int>] = [:]

    var isEmpty: Bool {
        locationsByRegion.isEmpty
    }

    mutating func reveal(
        region: NativeTimelineTextRegion,
        rangeLocation: Int
    ) {
        locationsByRegion[region, default: []].insert(rangeLocation)
    }

    func locations(
        in region: NativeTimelineTextRegion
    ) -> Set<Int> {
        locationsByRegion[region] ?? []
    }
}

/// Whole text spoiler ranges. A spoiler that spans several attribute runs,
/// such as one containing a link or mention, is one range, and adjacent
/// spoilers are separate ranges because each has its own attribute value. So
/// painting, hit-testing, reveal keys, and accessibility agree on location.
nonisolated enum NativeTimelineTextSpoilers {
    static func ranges(in value: NSAttributedString) -> [NSRange] {
        var result: [NSRange] = []
        value.enumerateAttribute(
            .discordMarkdownSpoiler,
            in: NSRange(location: 0, length: value.length)
        ) { rawValue, range, _ in
            if rawValue != nil {
                result.append(range)
            }
        }
        return result
    }

    static func hiddenRanges(
        in value: NSAttributedString,
        revealedLocations: Set<Int>
    ) -> [NSRange] {
        ranges(in: value).filter {
            !revealedLocations.contains($0.location)
        }
    }

    /// The whole spoiler containing `index`, matching ``ranges(in:)``.
    static func range(
        at index: Int,
        in value: NSAttributedString
    ) -> NSRange? {
        guard index >= 0, index < value.length else { return nil }
        var range = NSRange(location: 0, length: 0)
        guard value.attribute(
            .discordMarkdownSpoiler,
            at: index,
            longestEffectiveRange: &range,
            in: NSRange(location: 0, length: value.length)
        ) != nil,
            range.length > 0
        else { return nil }
        return range
    }
}

nonisolated struct NativeTimelineTextSpoilerRevealKey: Hashable {
    /// Message body text renders to the same string on every surface, so the
    /// timeline and previews such as forum post cards share its reveal state.
    static let messageContentID = "message-content"
    static let beginningDescriptionContentID = "beginning-description"

    let messageID: MessageID
    let contentID: String
    let contentHash: Int
    let rangeLocation: Int

    var item: NativeTimelineSpoilerRevealStore.Item {
        .text(contentID: contentID, contentHash: contentHash, rangeLocation: rangeLocation)
    }
}

/// Which spoilers the user has revealed: every kind of spoiler, keyed by its
/// message and the item within it. Reveals last until the conversation
/// changes, as Discord's do.
@MainActor
final class NativeTimelineSpoilerRevealStore {
    nonisolated enum Item: Hashable {
        /// An attachment, embed or component, by its reveal component ID.
        case media(componentID: String)
        case text(contentID: String, contentHash: Int, rangeLocation: Int)
    }

    private(set) var revealed: [MessageID: Set<Item>] = [:]
    var observers: [UUID: (MessageID) -> Void] = [:]

    /// Checked for every row on every scrolled frame, so it is kept, not found.
    private(set) var hasRevealedText = false

    func isMediaRevealed(
        _ key: NativeTimelineComponentRevealKey
    ) -> Bool {
        isRevealed(.media(componentID: key.componentID), in: key.messageID)
    }

    /// Whether each of a message's media, by reveal component ID, is revealed.
    func isMediaRevealed(in messageID: MessageID) -> (String) -> Bool {
        { [self] componentID in
            isMediaRevealed(NativeTimelineComponentRevealKey(messageID: messageID, componentID: componentID))
        }
    }

    @discardableResult
    func revealMedia(
        _ key: NativeTimelineComponentRevealKey
    ) -> Bool {
        reveal(.media(componentID: key.componentID), in: key.messageID)
    }

    func isTextRevealed(
        _ key: NativeTimelineTextSpoilerRevealKey
    ) -> Bool {
        isRevealed(key.item, in: key.messageID)
    }

    @discardableResult
    func revealText(
        _ key: NativeTimelineTextSpoilerRevealKey
    ) -> Bool {
        reveal(key.item, in: key.messageID)
    }

    func revealedTextLocations(
        messageID: MessageID,
        contentID: String,
        contentHash: Int
    ) -> Set<Int> {
        Set(
            (revealed[messageID] ?? []).compactMap {
                guard case let .text(id, hash, location) = $0,
                      id == contentID, hash == contentHash
                else { return nil }
                return location
            }
        )
    }

    func revealedTextLocations(
        messageID: MessageID,
        contentID: String,
        value: NSAttributedString
    ) -> Set<Int> {
        revealedTextLocations(
            messageID: messageID,
            contentID: contentID,
            contentHash: value.string.hashValue
        )
    }

    func reset() {
        let messageIDs = Array(revealed.keys)
        revealed.removeAll(keepingCapacity: true)
        hasRevealedText = false
        for messageID in messageIDs {
            notifyObservers(messageID: messageID)
        }
    }

    private func isRevealed(_ item: Item, in messageID: MessageID) -> Bool {
        revealed[messageID]?.contains(item) == true
    }

    private func reveal(_ item: Item, in messageID: MessageID) -> Bool {
        let inserted = revealed[messageID, default: []].insert(item).inserted
        if inserted {
            if case .text = item { hasRevealedText = true }
            notifyObservers(messageID: messageID)
        }
        return inserted
    }

    func observe(
        _ observer: @escaping (MessageID) -> Void
    ) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    func notifyObservers(messageID: MessageID) {
        for observer in observers.values {
            observer(messageID)
        }
    }
}

@MainActor
enum NativeTimelineSpoilerConcealmentPolicy {
    static func isConcealed(
        messageID: MessageID,
        contentID: String,
        isSpoiler: Bool,
        store: NativeTimelineSpoilerRevealStore
    ) -> Bool {
        isSpoiler
            && !store.isMediaRevealed(
                NativeTimelineComponentRevealKey(
                    messageID: messageID,
                    componentID: contentID
                )
            )
    }

    /// Whether an attachment still hides behind its spoiler cover.
    static func isConcealed(
        _ attachment: Attachment,
        in messageID: MessageID,
        store: NativeTimelineSpoilerRevealStore
    ) -> Bool {
        isConcealed(
            messageID: messageID,
            contentID: NativeTimelineComponentRevealKey.attachmentComponentID(attachment.id),
            isSpoiler: attachment.isSpoiler,
            store: store
        )
    }

    /// The embeds still hidden because the message links them inside a
    /// spoiler, as Discord hides them, by embed ID with their reveal keys.
    static func concealedEmbeds(
        in message: Message,
        store: NativeTimelineSpoilerRevealStore
    ) -> [String: NativeTimelineComponentRevealKey] {
        let spoileredURLs = spoileredEmbedURLs(in: message)
        // Rows draw often and almost none link a spoiler.
        guard !spoileredURLs.isEmpty else { return [:] }
        var result: [String: NativeTimelineComponentRevealKey] = [:]
        var occurrences: [URL: Int] = [:]
        for group in MessageEmbedPresentation.groupedEmbeds(message.embeds) {
            guard let url = group[0].url, spoileredURLs.contains(url) else { continue }
            // One link can carry several cards. A multi-image post's images
            // share their card's key, so the grid reveals as one preview.
            let key = NativeTimelineComponentRevealKey.embed(
                messageID: message.id, url: url, occurrence: occurrences[url, default: 0]
            )
            occurrences[url, default: 0] += 1
            guard !store.isMediaRevealed(key) else { continue }
            for embed in group { result[embed.id] = key }
        }
        return result
    }

    /// The embed addresses that came from spoilered links. A link preview can
    /// carry its page's canonical address rather than the link as written, as
    /// youtu.be's does. Such a preview belongs to the links on its site, or,
    /// failing those, to the links no preview names. It hides when those links
    /// are all spoilered; when only some are and several previews compete,
    /// any pairing is a guess, so the preview stays as is.
    nonisolated static func spoileredEmbedURLs(in message: Message) -> Set<URL> {
        guard !message.embeds.isEmpty, message.content.contains("||") else { return [] }
        let links = DiscordMarkdown.linkOccurrences(message.content)
        var result = Set(links.filter(\.isSpoiler).map(\.url))
        guard !result.isEmpty else { return [] }
        let embedURLs = Set(message.embeds.compactMap(\.url))
        // A <…> link never previews, so a card at its address came from another link.
        let linkURLs = Set(links.filter { !$0.suppressesPreview }.map(\.url))
        // One entry per address no preview names, spoilered only when every
        // copy Discord could preview is.
        var unmatchedLinks: [(url: URL, isSpoiler: Bool)] = []
        for link in links where !link.suppressesPreview && !embedURLs.contains(link.url) {
            if let index = unmatchedLinks.firstIndex(where: { $0.url == link.url }) {
                unmatchedLinks[index].isSpoiler = unmatchedLinks[index].isSpoiler && link.isSpoiler
            } else {
                unmatchedLinks.append((link.url, link.isSpoiler))
            }
        }
        var canonicalURLs: [URL] = []
        for embed in message.embeds where embed.type != "rich" {
            guard let url = embed.url, !linkURLs.contains(url), !canonicalURLs.contains(url) else { continue }
            canonicalURLs.append(url)
        }
        for url in canonicalURLs {
            let sameSite = unmatchedLinks.filter { site(of: $0.url) == site(of: url) }
            let candidates = !sameSite.isEmpty ? sameSite
                : canonicalURLs.count == 1 || unmatchedLinks.allSatisfy(\.isSpoiler) ? unmatchedLinks : []
            // Several candidates decide only when they all agree.
            if !candidates.isEmpty, candidates.allSatisfy(\.isSpoiler) { result.insert(url) }
        }
        return result
    }

    /// A host's last two labels, with the short hosts that redirect elsewhere
    /// mapped to their site.
    private nonisolated static func site(of url: URL) -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        return host == "youtu.be" ? "youtube.com" : host.split(separator: ".").suffix(2).joined(separator: ".")
    }

    static func hiddenContainerFrames(
        in layout: NativeTimelineComponentLayout,
        messageID: MessageID,
        store: NativeTimelineSpoilerRevealStore
    ) -> [CGRect] {
        let frames = layout.containers.compactMap { container in
            isConcealed(
                messageID: messageID,
                contentID: container.componentID,
                isSpoiler: container.isSpoiler,
                store: store
            ) ? container.frame : nil
        }
        return frames.filter { candidate in
            !frames.contains { other in
                other != candidate
                    && other.width * other.height
                        > candidate.width * candidate.height
                    && other.contains(
                        CGPoint(
                            x: candidate.midX,
                            y: candidate.midY
                        )
                    )
            }
        }
    }

    static func isInsideHiddenContainer(
        _ frame: CGRect,
        hiddenContainerFrames: [CGRect]
    ) -> Bool {
        hiddenContainerFrames.contains {
            $0.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
    }
}

extension NativeTimelineCanvasView {
    func reveal(
        _ key: NativeTimelineComponentRevealKey
    ) {
        guard let rowIndex = rowIndex(forMessageID: key.messageID) else { return }
        reveal(key, rowIndex: rowIndex)
    }

    func reveal(
        _ key: NativeTimelineComponentRevealKey,
        rowIndex: Int
    ) {
        guard items.indices.contains(rowIndex),
              items[rowIndex].messageID == key.messageID,
              !spoilerRevealStore.isMediaRevealed(key)
        else { return }
        if let cover = spoilerOverlays[key] {
            fadeOutSpoilerCover(
                [cover.frame],
                cornerRadius: cover.cornerRadius,
                duration: SpoilerAppearance.mediaRevealDuration,
                dropsPill: true
            )
        }
        spoilerRevealStore.revealMedia(key)
    }

    func installSpoilerRevealStore(
        _ store: NativeTimelineSpoilerRevealStore
    ) {
        guard spoilerRevealStore !== store else { return }
        if let spoilerRevealObserverID {
            spoilerRevealStore.removeObserver(spoilerRevealObserverID)
        }
        spoilerRevealStore = store
        spoilerRevealObserverID = store.observe { [weak self] messageID in
            self?.spoilerRevealStateDidChange(messageID: messageID)
        }
    }

    func spoilerRevealStateDidChange(messageID: MessageID) {
        // A forum post's starter message shares the post's ID with the
        // beginning row above it, so a message row takes precedence.
        guard let rowIndex = rowIndex(forMessageID: messageID)
            ?? items.firstIndex(where: { $0.beginning?.id.rawValue == messageID.rawValue })
        else { return }
        let identifier = items[rowIndex].identifier
        visibleMediaProjection = nil
        mediaKeysByIdentifier[identifier] = nil
        invalidateBitmap(identifier)
        requestMedia(for: items[rowIndex], at: rowIndex)
        setNeedsDisplay(rowFrame(at: rowIndex))
        window?.invalidateCursorRects(for: self)
        reconcileAnimatedMedia()
        reconcileSpoilerOverlays()
        // A reset reveal store hides a video playing in place again.
        reconcileInlinePlayers()
        rebuildAccessibilityProxy(for: identifier)
    }
}

struct NativeTimelineComponentRevealKey: Hashable {
    let messageID: MessageID
    let componentID: String

    /// Keyed by the link, as embed IDs are only positions: an edit that
    /// replaces the link must not inherit the old one's reveal.
    static func embed(messageID: MessageID, url: URL, occurrence: Int) -> Self {
        Self(messageID: messageID, componentID: "embed:\(occurrence):\(url.absoluteString)")
    }

    static func attachmentComponentID(_ attachmentID: String) -> String {
        "attachment:\(attachmentID)"
    }

    static func attachment(
        messageID: MessageID,
        attachmentID: String
    ) -> Self {
        Self(
            messageID: messageID,
            componentID: attachmentComponentID(attachmentID)
        )
    }
}
