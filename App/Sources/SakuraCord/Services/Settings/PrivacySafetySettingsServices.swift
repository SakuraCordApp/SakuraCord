import AppKit
import Foundation

nonisolated enum ExternalUploaderOfferPolicy: String, CaseIterable, Identifiable, Sendable {
    case ask
    case never

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .ask:
            LocalizedStringResource("Always Ask", bundle: #bundle)
        case .never:
            LocalizedStringResource("Never Offer", bundle: #bundle)
        }
    }
}

nonisolated struct PrivacySafetySettingsSnapshot: Equatable, Sendable {
    static let defaults = Self(externalUploaderOfferPolicy: .ask)

    var externalUploaderOfferPolicy: ExternalUploaderOfferPolicy
}

@MainActor
final class PrivacySafetySettingsStore {
    static let shared = PrivacySafetySettingsStore()

    private let preferences: SettingsPreferenceStore

    init(preferences: SettingsPreferenceStore = .shared) {
        self.preferences = preferences
    }

    func load() -> PrivacySafetySettingsSnapshot {
        var value = PrivacySafetySettingsSnapshot.defaults
        if case let .string(rawValue) = preferences.value(for: .externalUploaderPolicy),
           let policy = ExternalUploaderOfferPolicy(rawValue: rawValue)
        {
            value.externalUploaderOfferPolicy = policy
        }
        return value
    }

    func save(_ value: PrivacySafetySettingsSnapshot) {
        preferences.set(
            .string(value.externalUploaderOfferPolicy.rawValue),
            for: .externalUploaderPolicy
        )
    }
}

nonisolated struct ExternalLinkSafetyAssessment: Equatable, Sendable {
    let url: URL
    let domain: String
    let warnings: [String]
    let isAllowed: Bool

    var isSuspicious: Bool { !warnings.isEmpty }
}

nonisolated enum ExternalLinkSafetyPolicy {
    static func assess(
        _ url: URL,
        displayedText: String? = nil
    ) -> ExternalLinkSafetyAssessment {
        let scheme = url.scheme?.lowercased()
        let host = url.host(percentEncoded: false)?.lowercased() ?? ""
        guard scheme == "https" || scheme == "http", !host.isEmpty else {
            return ExternalLinkSafetyAssessment(
                url: url,
                domain: host.isEmpty ? localized("Unknown destination") : host,
                warnings: [localized("The destination does not use a supported web address.")],
                isAllowed: false
            )
        }

        var warnings: [String] = []
        if scheme == "http" {
            warnings.append(localized("This connection is not encrypted."))
        }
        if url.user != nil || url.password != nil {
            warnings.append(localized(
                "The address disguises its destination with user information."
            ))
        }
        if host.contains("xn--") || host.unicodeScalars.contains(where: { !$0.isASCII }) {
            warnings.append(localized(
                "The domain contains an encoded or non-ASCII name that may resemble another site."
            ))
        }
        if host.split(separator: ".").count < 2 || host.contains("..") {
            warnings.append(localized(
                "The destination has an unusual or malformed host name."
            ))
        }
        if resemblesTrustedDomain(host) {
            warnings.append(localized(
                "The domain contains the name of a known service but is not that service's domain."
            ))
        }
        if let displayedHost = displayedHost(in: displayedText),
           displayedHost != host
        {
            warnings.append(localized(
                "The displayed address names \(displayedHost), but the link opens \(host)."
            ))
        }

        return ExternalLinkSafetyAssessment(
            url: url,
            domain: host,
            warnings: warnings,
            isAllowed: true
        )
    }

    private static func resemblesTrustedDomain(_ host: String) -> Bool {
        trustedDomains.contains { trusted in
            host != trusted
                && !host.hasSuffix(".\(trusted)")
                && host.contains(trusted)
        }
    }

    private static func displayedHost(in displayedText: String?) -> String? {
        guard let displayedText else { return nil }
        let trimmed = displayedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(".") else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        return URL(string: candidate)?.host(percentEncoded: false)?.lowercased()
    }

    private static let trustedDomains = [
        "discord.com", "discordapp.com", "catbox.moe",
    ]

    private static func localized(_ value: String.LocalizationValue) -> String {
        String(localized: LocalizedStringResource(value, bundle: #bundle))
    }
}

@MainActor
final class ExternalLinkConfirmationPresenter {
    static let shared = ExternalLinkConfirmationPresenter()

    private var activeAlert: NSAlert?
    private let opener: (URL) -> Void
    private let windowProvider: () -> NSWindow?

    init(
        opener: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        windowProvider: @escaping () -> NSWindow? = {
            NSApp.keyWindow ?? NSApp.mainWindow
        }
    ) {
        self.opener = opener
        self.windowProvider = windowProvider
    }

    func present(_ assessment: ExternalLinkSafetyAssessment) {
        guard assessment.isAllowed else {
            NSSound.beep()
            return
        }
        guard activeAlert == nil, let window = windowProvider() else {
            NSSound.beep()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = assessment.isSuspicious ? .critical : .warning
        alert.messageText = assessment.isSuspicious
            ? String(localized: LocalizedStringResource("Review Suspicious Link", bundle: #bundle))
            : String(localized: LocalizedStringResource("Open External Link?", bundle: #bundle))
        let warningText = assessment.warnings.isEmpty
            ? String(localized: LocalizedStringResource(
                "SakuraCord cannot determine whether an external link is safe.",
                bundle: #bundle
            ))
            : assessment.warnings.joined(separator: "\n")
        alert.informativeText = String(localized: LocalizedStringResource(
            "Domain: \(assessment.domain)\n\n\(warningText)\n\n\(assessment.url.absoluteString)",
            bundle: #bundle
        ))
        let openButton = alert.addButton(withTitle: String(localized: LocalizedStringResource(
            "Open Link",
            bundle: #bundle
        )))
        openButton.hasDestructiveAction = assessment.isSuspicious
        alert.addButton(withTitle: String(localized: LocalizedStringResource(
            "Cancel",
            bundle: #bundle
        )))
        activeAlert = alert
        alert.beginSheetModal(for: window) { [weak self, url = assessment.url] response in
            guard let self else { return }
            activeAlert = nil
            if response == .alertFirstButtonReturn {
                opener(url)
            }
        }
    }
}

@MainActor
extension AppModel {
    var privacySafetySettings: PrivacySafetySettingsSnapshot {
        get { privacySafetySettingsStore.load() }
        set { privacySafetySettingsStore.save(newValue) }
    }

    func applyPrivacySafetySettings(_ value: PrivacySafetySettingsSnapshot) {
        privacySafetySettings = value
    }
}
