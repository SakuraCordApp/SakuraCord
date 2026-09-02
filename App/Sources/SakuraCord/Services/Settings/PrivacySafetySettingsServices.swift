import AppKit
import Foundation

nonisolated enum ExternalLinkConfirmationPolicy: String, CaseIterable, Identifiable, Sendable {
    case untrustedDomains
    case allLinks
    case noLinks

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .untrustedDomains:
            LocalizedStringResource("Untrusted Domains", bundle: #bundle)
        case .allLinks:
            LocalizedStringResource("All Links", bundle: #bundle)
        case .noLinks:
            LocalizedStringResource("No Links", bundle: #bundle)
        }
    }

    var systemImage: String {
        switch self {
        case .untrustedDomains:
            "shield"
        case .allLinks:
            "globe"
        case .noLinks:
            "hand.raised.slash"
        }
    }

    func requiresConfirmation(
        for domain: String,
        trustedDomains: [String]
    ) -> Bool {
        switch self {
        case .untrustedDomains:
            !trustedDomains.contains(domain)
        case .allLinks:
            true
        case .noLinks:
            false
        }
    }
}

nonisolated enum ExternalLinkTrustedDomain {
    static func normalized(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: candidate),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let rawHost = components.host?.lowercased()
        else { return nil }

        let host = rawHost.last == "." ? String(rawHost.dropLast()) : rawHost
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              host.utf8.count <= 253,
              labels.allSatisfy({ label in
                  !label.isEmpty
                      && label.utf8.count <= 63
                      && label.first != "-"
                      && label.last != "-"
                      && label.allSatisfy { character in
                          character.isASCII
                              && (character.isLetter || character.isNumber || character == "-")
                      }
              })
        else { return nil }
        return host
    }

    static func normalizedList(_ domains: [String]) -> [String] {
        Array(Set(domains.compactMap(normalized))).sorted()
    }
}

nonisolated struct PrivacySafetySettingsSnapshot: Equatable, Sendable {
    static let defaults = Self(
        externalLinkConfirmationPolicy: .untrustedDomains,
        trustedDomains: []
    )

    var externalLinkConfirmationPolicy: ExternalLinkConfirmationPolicy
    var trustedDomains: [String]
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
        if case let .string(rawValue) = preferences.value(for: .externalLinkProtection),
           let policy = ExternalLinkConfirmationPolicy(rawValue: rawValue)
        {
            value.externalLinkConfirmationPolicy = policy
        }
        if case let .strings(domains) = preferences.value(for: .trustedDomains) {
            value.trustedDomains = ExternalLinkTrustedDomain.normalizedList(domains)
        }
        return value
    }

    func save(_ value: PrivacySafetySettingsSnapshot) {
        preferences.set(
            .string(value.externalLinkConfirmationPolicy.rawValue),
            for: .externalLinkProtection
        )
        preferences.set(
            .strings(ExternalLinkTrustedDomain.normalizedList(value.trustedDomains)),
            for: .trustedDomains
        )
    }

    func trust(_ domain: String) {
        guard let domain = ExternalLinkTrustedDomain.normalized(domain) else { return }
        var value = load()
        guard !value.trustedDomains.contains(domain) else { return }
        value.trustedDomains.append(domain)
        save(value)
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
    private let settingsStore: PrivacySafetySettingsStore
    private let opener: (URL) -> Void
    private let windowProvider: () -> NSWindow?

    init(
        settingsStore: PrivacySafetySettingsStore = .shared,
        opener: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        windowProvider: @escaping () -> NSWindow? = {
            NSApp.keyWindow ?? NSApp.mainWindow
        }
    ) {
        self.settingsStore = settingsStore
        self.opener = opener
        self.windowProvider = windowProvider
    }

    func present(_ assessment: ExternalLinkSafetyAssessment) {
        guard assessment.isAllowed else {
            NSSound.beep()
            return
        }
        let settings = settingsStore.load()
        guard settings.externalLinkConfirmationPolicy.requiresConfirmation(
            for: assessment.domain,
            trustedDomains: settings.trustedDomains
        ) else {
            opener(assessment.url)
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
        let trustDomainCheckbox: NSButton? = if settings.externalLinkConfirmationPolicy
            == .untrustedDomains
        {
            NSButton(
                checkboxWithTitle: String(localized: LocalizedStringResource(
                    "Trust \(assessment.domain) for future links",
                    bundle: #bundle,
                    comment: "Checkbox in an external-link warning; the variable is the exact destination domain."
                )),
                target: nil,
                action: nil
            )
        } else {
            nil
        }
        alert.accessoryView = trustDomainCheckbox
        activeAlert = alert
        alert.beginSheetModal(for: window) { [weak self, domain = assessment.domain, url = assessment.url] response in
            guard let self else { return }
            activeAlert = nil
            if response == .alertFirstButtonReturn {
                if trustDomainCheckbox?.state == .on {
                    settingsStore.trust(domain)
                }
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
