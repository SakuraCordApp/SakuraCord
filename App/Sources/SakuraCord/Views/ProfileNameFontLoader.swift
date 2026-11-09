import AppKit
import CoreText
import DiscordProtocol
import SakuraCordModels
import Synchronization

/// Core Text font descriptors are immutable and documented as safe to share
/// across threads; the SDK does not yet express that Sendable conformance.
nonisolated struct ProfileNameFontDescriptor: @unchecked Sendable {
    let value: CTFontDescriptor
}

/// Immutable fonts are shared by native painters and background member preparation.
/// Downloading and decoding never happen in a layout or drawing callback.
nonisolated enum ProfileNameFontCache {
    static let defaultFontID = DisplayNameStyle().fontID

    /// Discord's default typeface follows the app's native font on every surface.
    static func customDefinition(for id: Int?) -> ProfileNameFont? {
        guard let id, id != defaultFontID else { return nil }
        return DiscordProfileNameStyles.catalog.fonts.first { $0.id == id }
    }

    private struct Key: Hashable {
        let id: Int
        let size: CGFloat
    }

    // CTFont is immutable and supports concurrent use, like its descriptor.
    private struct Face: @unchecked Sendable {
        let value: CTFont
    }

    private struct State {
        var descriptors: [Int: ProfileNameFontDescriptor] = [:]
        var fonts: [Key: Face] = [:]
        var revision: UInt64 = 0
    }

    private static let state = Mutex(State())

    static var revision: UInt64 { state.withLock { $0.revision } }

    static func font(id: Int?, fallback: NSFont) -> NSFont {
        guard let id, id != defaultFontID else { return fallback }
        let key = Key(id: id, size: fallback.pointSize)
        let face: Face? = state.withLock { state in
            if let font = state.fonts[key] { return font }
            guard let descriptor = state.descriptors[id] else { return nil }
            let font = Face(value: CTFontCreateWithFontDescriptor(descriptor.value, key.size, nil))
            state.fonts[key] = font
            return font
        }
        return face.map { $0.value as NSFont } ?? fallback
    }

    static func contains(_ id: Int) -> Bool {
        state.withLock { $0.descriptors[id] != nil }
    }

    static func insert(_ descriptor: ProfileNameFontDescriptor, id: Int) {
        FileHandle.standardError.write(Data("FLAKYDIAG font insert id=\(id)\n".utf8))
        state.withLock {
            $0.descriptors[id] = descriptor
            $0.revision &+= 1
        }
    }
}

/// Loads first-party font bytes through the persistent media cache, without
/// installing or registering fonts on the Mac.
@MainActor
final class ProfileNameFontLoader {
    static let shared = ProfileNameFontLoader()
    static let didLoadFonts = Notification.Name("ProfileNameFontsDidLoad")

    private var loads: [Int: Task<ProfileNameFontDescriptor, any Error>] = [:]
    private var requestedIDs: Set<Int> = []
    private var retryAfter: [Int: Date] = [:]
    private var pendingIDs: Set<Int> = []
    private var notificationTask: Task<Void, Never>?

    func resolvedFont(for user: User?, fallback: NSFont) -> NSFont {
        let id = user?.displayNameStyle?.fontID
        request(id: id)
        return ProfileNameFontCache.font(id: id, fallback: fallback)
    }

    func request(id: Int?) {
        guard let id, !ProfileNameFontCache.contains(id),
              !requestedIDs.contains(id),
              retryAfter[id].map({ $0 <= .now }) ?? true,
              let definition = ProfileNameFontCache.customDefinition(for: id)
        else { return }
        requestedIDs.insert(id)
        Task {
            defer { requestedIDs.remove(id) }
            do {
                _ = try await font(definition, size: 13)
            } catch {
                retryAfter[id] = .now.addingTimeInterval(60)
            }
        }
    }

    func font(_ definition: ProfileNameFont, size: CGFloat) async throws -> NSFont {
        let fallback = NSFont.systemFont(ofSize: size, weight: .bold)
        guard definition.id != ProfileNameFontCache.defaultFontID, let url = definition.assetURL else { return fallback }
        if !ProfileNameFontCache.contains(definition.id) {
            let task: Task<ProfileNameFontDescriptor, any Error>
            if let existing = loads[definition.id] {
                task = existing
            } else {
                task = Task.detached(priority: .utility) {
                    let data = try await SharedMediaDataLoader.shared.data(for: url)
                    await AppScrollWorkGate.waitUntilInactive()
                    let values = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor]
                    guard let descriptor = values?.first else { throw URLError(.cannotDecodeContentData) }
                    let font = CTFontCreateWithFontDescriptor(descriptor, 24, nil)
                    guard CTFontCopyPostScriptName(font) as String == definition.postScriptName
                    else { throw URLError(.cannotDecodeContentData) }
                    // Core Text otherwise lazily resolves the font's language
                    // metadata during its first glyph draw on the main thread.
                    _ = CTFontCopySupportedLanguages(font)
                    return ProfileNameFontDescriptor(value: descriptor)
                }
                loads[definition.id] = task
            }
            do {
                let descriptor = try await task.value
                await AppScrollWorkGate.waitUntilInactive()
                if !ProfileNameFontCache.contains(definition.id) {
                    ProfileNameFontCache.insert(descriptor, id: definition.id)
                    announceLoadedFont(definition.id)
                }
                loads[definition.id] = nil
            } catch {
                loads[definition.id] = nil
                throw error
            }
        }
        try Task.checkCancellation()
        return ProfileNameFontCache.font(id: definition.id, fallback: fallback)
    }

    private func announceLoadedFont(_ id: Int) {
        pendingIDs.insert(id)
        guard notificationTask == nil else { return }
        notificationTask = Task {
            try? await Task.sleep(for: .milliseconds(16))
            let ids = pendingIDs
            pendingIDs.removeAll()
            notificationTask = nil
            NotificationCenter.default.post(name: Self.didLoadFonts, object: nil, userInfo: ["fontIDs": ids])
        }
    }
}
