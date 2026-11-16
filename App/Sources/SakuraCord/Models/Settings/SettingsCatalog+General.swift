import Foundation

nonisolated extension SettingsCatalog {
    static let generalPage = page(
        .general, group: .preferences, title: "General", image: "gearshape",
        help: "Choose startup, text input, emoji, restoration, and confirmation behavior.",
        keywords: ["startup", "launch", "restore", "confirmation", "quit", "spelling", "emoji"]
    )

    static let generalControls: [SettingsControlMetadata] = [
        control(
            .launchAtLogin,
            page: .general,
            section: .startupRestoration,
            label: "Open at login",
            help: "Ask macOS to launch SakuraCord after this user logs in.",
            keywords: ["startup", "login item", "open automatically", "Service Management"]
        ),
        control(
            .launchDestination,
            page: .general,
            section: .startupRestoration,
            label: "Launch destination",
            help: "Choose which account and safely restored conversation SakuraCord opens at launch.",
            keywords: ["last conversation", "last location", "account picker", "startup page"]
        ),
        control(
            .confirmQuitActiveWork,
            page: .general,
            section: .confirmations,
            label: "Confirm quitting during calls or uploads",
            help: "Ask before quitting during a call, screen share, or active upload.",
            keywords: ["quit warning", "call", "screen share", "upload"]
        ),
        control(
            .sendWithReturn, page: .general, section: .generalTextInput,
            label: "Send messages with",
            help: "Choose Return or Command-Return to send messages.",
            keywords: ["enter", "return", "command", "send", "newline"]
        ),
        control(
            .spellCheck, page: .general, section: .generalTextInput,
            label: "Check spelling while typing",
            help: "Use AppKit's continuous spell checker in the real message composer.",
            keywords: ["spellcheck", "spelling", "typo"]
        ),
        control(
            .automaticCorrection, page: .general, section: .generalTextInput,
            label: "Correct spelling automatically",
            help: "Allow the native text system to apply spelling corrections in the composer.",
            keywords: ["autocorrect", "correction", "typing"]
        ),
        control(
            .smartQuotes, page: .general, section: .generalTextInput,
            label: "Smart quotes",
            help: "Allow the native text system to substitute typographic quotation marks.",
            keywords: ["curly quotes", "quotation", "substitution"]
        ),
        control(
            .smartDashes, page: .general, section: .generalTextInput,
            label: "Smart dashes",
            help: "Allow the native text system to substitute typographic dashes.",
            keywords: ["em dash", "hyphen", "substitution"]
        ),
        control(
            .emojiSkinTone, page: .general, section: .generalEmoji,
            label: "Default emoji skin tone",
            help: "Choose the app-wide skin-tone modifier used by the native emoji picker.",
            keywords: ["modifier", "hand", "tone", "emoji"]
        ),
    ]
}
