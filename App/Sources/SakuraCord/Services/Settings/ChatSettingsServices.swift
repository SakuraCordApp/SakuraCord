import AppKit
import Foundation

nonisolated enum ChatReadAcknowledgementMode: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case manual

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .automatic: LocalizedStringResource("Automatically", bundle: #bundle)
        case .manual: LocalizedStringResource("Manually", bundle: #bundle)
        }
    }
}

nonisolated enum ChatSpoilerRevealMode: String, CaseIterable, Identifiable, Sendable {
    case click
    case optionClick
    case always

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .click: LocalizedStringResource("Click", bundle: #bundle)
        case .optionClick: LocalizedStringResource("Option-click", bundle: #bundle)
        case .always: LocalizedStringResource("Always", bundle: #bundle)
        }
    }

    func permitsReveal(modifierFlags: NSEvent.ModifierFlags) -> Bool {
        switch self {
        case .click, .always: true
        case .optionClick: modifierFlags.contains(.option)
        }
    }
}

nonisolated enum ChatInlineMediaSize: String, CaseIterable, Identifiable, Sendable {
    case compact
    case medium
    case large

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .compact: LocalizedStringResource("Compact", bundle: #bundle)
        case .medium: LocalizedStringResource("Medium", bundle: #bundle)
        case .large: LocalizedStringResource("Large", bundle: #bundle)
        }
    }

    var maximumWidth: CGFloat {
        switch self {
        case .compact: 360
        case .medium: 520
        case .large: 680
        }
    }
}

nonisolated struct ChatSettingsSnapshot: Equatable, Sendable {
    static let defaults = Self(
        sendsWithReturn: true,
        checksSpelling: false,
        correctsSpellingAutomatically: false,
        usesSmartQuotes: false,
        usesSmartDashes: false,
        sendsTypingIndicators: true,
        focusesComposerOnTyping: true,
        readAcknowledgementMode: .automatic,
        showsEditedMarkers: true,
        expandsEmbedsByDefault: true,
        spoilerRevealMode: .click,
        opensDiscordLinksInternally: true,
        autoplaysGIFs: true,
        autoplaysAnimatedStickers: true,
        autoplaysInlineVideos: true,
        showsAutomaticLinkPreviews: true,
        inlineMediaSize: .medium,
        reducesAnimatedMedia: false,
        emojiSkinTone: .standard
    )

    var sendsWithReturn: Bool
    var checksSpelling: Bool
    var correctsSpellingAutomatically: Bool
    var usesSmartQuotes: Bool
    var usesSmartDashes: Bool
    var sendsTypingIndicators: Bool
    var focusesComposerOnTyping: Bool
    var readAcknowledgementMode: ChatReadAcknowledgementMode
    var showsEditedMarkers: Bool
    var expandsEmbedsByDefault: Bool
    var spoilerRevealMode: ChatSpoilerRevealMode
    var opensDiscordLinksInternally: Bool
    var autoplaysGIFs: Bool
    var autoplaysAnimatedStickers: Bool
    var autoplaysInlineVideos: Bool
    var showsAutomaticLinkPreviews: Bool
    var inlineMediaSize: ChatInlineMediaSize
    var reducesAnimatedMedia: Bool
    var emojiSkinTone: NativeEmojiSkinTone
}

nonisolated enum ChatCharacterLimitPolicy {
    static let standardLimit = 2_000
    static let premiumLimit = 4_000

    static func limit(premiumType: Int?) -> Int {
        (premiumType ?? 0) > 0 ? premiumLimit : standardLimit
    }

    static func shouldShowCounter(characterCount: Int, limit: Int) -> Bool {
        characterCount >= limit - 200
    }

    static func shouldShowCounter(characterCount: Int, premiumType: Int?) -> Bool {
        shouldShowCounter(
            characterCount: characterCount,
            limit: limit(premiumType: premiumType)
        )
    }

    static func isWithinLimit(characterCount: Int, premiumType: Int?) -> Bool {
        characterCount <= limit(premiumType: premiumType)
    }
}

@MainActor
enum ComposerTextCheckingConfiguration {
    static func apply(_ settings: ChatSettingsSnapshot, to textView: NSTextView) {
        textView.isContinuousSpellCheckingEnabled = settings.checksSpelling
        textView.isAutomaticSpellingCorrectionEnabled = settings.correctsSpellingAutomatically
        textView.isAutomaticQuoteSubstitutionEnabled = settings.usesSmartQuotes
        textView.isAutomaticDashSubstitutionEnabled = settings.usesSmartDashes
    }
}

@MainActor
final class ChatSettingsStore {
    static let shared = ChatSettingsStore()

    private let preferences: SettingsPreferenceStore

    init(preferences: SettingsPreferenceStore = .shared) {
        self.preferences = preferences
    }

    func load() -> ChatSettingsSnapshot {
        var value = ChatSettingsSnapshot.defaults
        value.sendsWithReturn = bool(.sendWithReturn) ?? value.sendsWithReturn
        value.checksSpelling = bool(.chatSpellCheck) ?? value.checksSpelling
        value.correctsSpellingAutomatically = bool(.chatAutomaticCorrection)
            ?? value.correctsSpellingAutomatically
        value.usesSmartQuotes = bool(.chatSmartQuotes) ?? value.usesSmartQuotes
        value.usesSmartDashes = bool(.chatSmartDashes) ?? value.usesSmartDashes
        value.sendsTypingIndicators = bool(.chatTypingIndicators)
            ?? value.sendsTypingIndicators
        value.focusesComposerOnTyping = bool(.chatFocusComposerOnTyping)
            ?? value.focusesComposerOnTyping
        value.readAcknowledgementMode = enumValue(.chatReadAcknowledgement)
            ?? value.readAcknowledgementMode
        value.showsEditedMarkers = bool(.chatEditedMarkers) ?? value.showsEditedMarkers
        value.expandsEmbedsByDefault = bool(.chatExpandEmbeds)
            ?? value.expandsEmbedsByDefault
        value.spoilerRevealMode = enumValue(.chatSpoilerReveal) ?? value.spoilerRevealMode
        value.opensDiscordLinksInternally = bool(.chatInternalDiscordLinks)
            ?? value.opensDiscordLinksInternally
        value.autoplaysGIFs = bool(.chatAutoplayGIFs) ?? value.autoplaysGIFs
        value.autoplaysAnimatedStickers = bool(.chatAutoplayStickers)
            ?? value.autoplaysAnimatedStickers
        value.autoplaysInlineVideos = bool(.chatAutoplayVideos)
            ?? value.autoplaysInlineVideos
        value.showsAutomaticLinkPreviews = bool(.chatLinkPreviews)
            ?? value.showsAutomaticLinkPreviews
        value.inlineMediaSize = enumValue(.chatInlineMediaSize) ?? value.inlineMediaSize
        value.reducesAnimatedMedia = bool(.reduceAnimatedMedia)
            ?? value.reducesAnimatedMedia
        value.emojiSkinTone = enumValue(.chatEmojiSkinTone) ?? value.emojiSkinTone
        return value
    }

    func save(_ value: ChatSettingsSnapshot) {
        preferences.set(.bool(value.sendsWithReturn), for: .sendWithReturn)
        preferences.set(.bool(value.checksSpelling), for: .chatSpellCheck)
        preferences.set(
            .bool(value.correctsSpellingAutomatically),
            for: .chatAutomaticCorrection
        )
        preferences.set(.bool(value.usesSmartQuotes), for: .chatSmartQuotes)
        preferences.set(.bool(value.usesSmartDashes), for: .chatSmartDashes)
        preferences.set(.bool(value.sendsTypingIndicators), for: .chatTypingIndicators)
        preferences.set(.bool(value.focusesComposerOnTyping), for: .chatFocusComposerOnTyping)
        preferences.set(
            .string(value.readAcknowledgementMode.rawValue),
            for: .chatReadAcknowledgement
        )
        preferences.set(.bool(value.showsEditedMarkers), for: .chatEditedMarkers)
        preferences.set(.bool(value.expandsEmbedsByDefault), for: .chatExpandEmbeds)
        preferences.set(.string(value.spoilerRevealMode.rawValue), for: .chatSpoilerReveal)
        preferences.set(
            .bool(value.opensDiscordLinksInternally),
            for: .chatInternalDiscordLinks
        )
        preferences.set(.bool(value.autoplaysGIFs), for: .chatAutoplayGIFs)
        preferences.set(
            .bool(value.autoplaysAnimatedStickers),
            for: .chatAutoplayStickers
        )
        preferences.set(.bool(value.autoplaysInlineVideos), for: .chatAutoplayVideos)
        preferences.set(
            .bool(value.showsAutomaticLinkPreviews),
            for: .chatLinkPreviews
        )
        preferences.set(.string(value.inlineMediaSize.rawValue), for: .chatInlineMediaSize)
        preferences.set(.bool(value.reducesAnimatedMedia), for: .reduceAnimatedMedia)
        preferences.set(.string(value.emojiSkinTone.rawValue), for: .chatEmojiSkinTone)
    }

    private func bool(_ id: SettingsControlID) -> Bool? {
        guard case let .bool(value) = preferences.value(for: id) else { return nil }
        return value
    }

    private func enumValue<Value: RawRepresentable>(
        _ id: SettingsControlID
    ) -> Value? where Value.RawValue == String {
        guard case let .string(value) = preferences.value(for: id) else { return nil }
        return Value(rawValue: value)
    }
}

@MainActor
extension AppModel {
    func applyChatSettings(
        _ value: ChatSettingsSnapshot,
        persists: Bool = true
    ) {
        let previous = chatSettings
        chatSettings = value
        timelineSpoilerRevealStore.revealMode = value.spoilerRevealMode
        if persists {
            ChatSettingsStore.shared.save(value)
        }
        if previous.sendsTypingIndicators, !value.sendsTypingIndicators {
            stopLocalTyping(clearThrottle: false)
        }
        if previous.readAcknowledgementMode == .automatic,
           value.readAcknowledgementMode == .manual
        {
            cancelScheduledAutomaticAcknowledgements()
        }
        let timelinePresentationChanged =
            previous.showsEditedMarkers != value.showsEditedMarkers
                || previous.expandsEmbedsByDefault != value.expandsEmbedsByDefault
                || previous.showsAutomaticLinkPreviews != value.showsAutomaticLinkPreviews
                || previous.inlineMediaSize != value.inlineMediaSize
                || previous.spoilerRevealMode != value.spoilerRevealMode
                || previous.autoplaysGIFs != value.autoplaysGIFs
                || previous.autoplaysAnimatedStickers
                    != value.autoplaysAnimatedStickers
                || previous.autoplaysInlineVideos != value.autoplaysInlineVideos
                || previous.reducesAnimatedMedia != value.reducesAnimatedMedia
        if timelinePresentationChanged {
            invalidateTimelinePresentation()
        }
    }
}
