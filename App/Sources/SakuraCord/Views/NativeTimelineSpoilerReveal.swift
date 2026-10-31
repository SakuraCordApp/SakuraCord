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

    /// The embeds still hidden because the message links them inside a
    /// spoiler, as Discord hides them, by embed ID with their reveal keys.
    static func concealedEmbeds(
        in message: Message,
        store: NativeTimelineSpoilerRevealStore
    ) -> [String: NativeTimelineComponentRevealKey] {
        guard !message.embeds.isEmpty, message.content.contains("||") else { return [:] }
        let spoileredURLs = spoileredEmbedURLs(in: message)
        var result: [String: NativeTimelineComponentRevealKey] = [:]
        var occurrences: [URL: Int] = [:]
        for embed in message.embeds {
            guard let url = embed.url, spoileredURLs.contains(url) else { continue }
            // One link can carry several cards, such as a post's images.
            let key = NativeTimelineComponentRevealKey.embed(
                messageID: message.id, url: url, occurrence: occurrences[url, default: 0]
            )
            occurrences[url, default: 0] += 1
            if !store.isMediaRevealed(key) { result[embed.id] = key }
        }
        return result
    }

    /// The embed addresses that came from spoilered links. A link preview can
    /// carry its page's canonical address rather than the link as written, as
    /// youtu.be's does. Such a preview belongs to the links on its site, or,
    /// failing those, to the links no preview names. It hides when those links
    /// are all spoilered; when only some are and several previews compete,
    /// any pairing is a guess, so the preview stays as is.
    static func spoileredEmbedURLs(in message: Message) -> Set<URL> {
        let links = DiscordMarkdown.linkOccurrences(message.content)
        var result = Set(links.filter(\.isSpoiler).map(\.url))
        guard !result.isEmpty else { return [] }
        let embedURLs = Set(message.embeds.compactMap(\.url))
        let linkURLs = Set(links.map(\.url))
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
    private static func site(of url: URL) -> String? {
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

    static func shouldAnimate(
        messageID: MessageID,
        contentID: String,
        isSpoiler: Bool,
        store: NativeTimelineSpoilerRevealStore
    ) -> Bool {
        !isConcealed(
            messageID: messageID,
            contentID: contentID,
            isSpoiler: isSpoiler,
            store: store
        )
    }
}
