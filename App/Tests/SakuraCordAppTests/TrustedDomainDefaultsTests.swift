@testable import SakuraCord
import Foundation
import Testing

@Test func `Bundled trusted rules are valid and cover international and regional services`() throws {
    let url = try #require(Bundle.module.url(forResource: "trusted-domains", withExtension: "json"))
    let bundled = try JSONDecoder().decode([String].self, from: Data(contentsOf: url))
    let rules = ExternalLinkTrustedDomain.defaults
    #expect(bundled == rules)
    #expect(!rules.isEmpty)
    #expect(rules.contains("microsoft.com"))
    #expect(rules.contains("*.microsoft.com"))
    for host in [
        "support.microsoft.com", "docs.github.com", "old.reddit.com", "support.discord.com",
        "www.mercadolivre.com.br", "www.jumia.co.ke", "www.aljazeera.net", "www.flipkart.com",
        "www.naver.com", "www.yahoo.co.jp", "www.grab.com", "www.abc.net.au",
    ] {
        #expect(!ExternalLinkConfirmationPolicy.untrustedDomains.requiresConfirmation(for: host, trustedDomains: rules))
    }
    for host in ["customer.github.io", "customer.pages.dev", "customer.azurewebsites.net", "customer.wordpress.com"] {
        #expect(ExternalLinkConfirmationPolicy.untrustedDomains.requiresConfirmation(for: host, trustedDomains: rules))
    }
    #expect(PrivacySafetySettingsSnapshot.defaults.trustedDomains == rules)
}

@MainActor
@Test(arguments: [[], ["Example.COM", "example.com", "*.custom.example"]])
func `Existing lists are seeded once and subsequent edits survive store reconstruction`(_ saved: [String]) {
    let defaults = InMemoryPreferences()
    defaults.set(saved, forKey: "settings.privacy.trustedDomains")
    let preferences = SettingsPreferenceStore(defaults: defaults)
    let store = PrivacySafetySettingsStore(preferences: preferences)
    let expected = ExternalLinkTrustedDomain.normalizedList(saved + ExternalLinkTrustedDomain.defaults)
    #expect(store.load().trustedDomains == expected)

    var settings = store.load()
    settings.trustedDomains = ["*.custom.example"]
    store.save(settings)
    let reopened = SettingsPreferenceStore(defaults: defaults)
    let reopenedStore = PrivacySafetySettingsStore(preferences: reopened)
    #expect(reopenedStore.load().trustedDomains == ["*.custom.example"])

    settings.trustedDomains = []
    reopenedStore.save(settings)
    let emptiedStore = PrivacySafetySettingsStore(preferences: SettingsPreferenceStore(defaults: defaults))
    #expect(emptiedStore.load().trustedDomains.isEmpty)

    reopened.reset(scope: .appWide, page: .privacySafety)
    #expect(emptiedStore.load().trustedDomains == ExternalLinkTrustedDomain.defaults)
    #expect(PrivacySafetySettingsStore(preferences: SettingsPreferenceStore(defaults: defaults)).load() == .defaults)
}

@Test(arguments: ["*", "*.com", "*.co.uk", "*.github.io", "*.pages.dev", "*.azurewebsites.net", "*.kawasaki.jp", "*.foo.kawasaki.jp", "foo.*.example.com", "*example.com", "*.*.example.com", "*.127.0.0.1", "*.https://example.com", "https://*.example.com", "*.example.com/path"])
func `Wildcard rules reject registries shared hosts IPs and misplaced stars`(_ input: String) {
    #expect(ExternalLinkTrustedDomain.normalized(input) == nil)
}

@Test func `Wildcard normalization and matching preserve hostname boundaries and PSL exceptions`() {
    #expect(ExternalLinkTrustedDomain.normalized(" *.Example.COM. ") == "*.example.com")
    #expect(ExternalLinkTrustedDomain.normalized("*.www.ck") == "*.www.ck")
    #expect(ExternalLinkTrustedDomain.normalized("*.city.kawasaki.jp") == "*.city.kawasaki.jp")
    for host in ["sub.example.com", "a.b.example.com", "SUB.EXAMPLE.COM", "sub.example.com."] {
        #expect(ExternalLinkTrustedDomain.matches(host, rule: "*.example.com"))
    }
    for host in ["example.com", "evilexample.com", "example.com.evil.example", "sub.example.com.evil.example", "sub..example.com"] {
        #expect(!ExternalLinkTrustedDomain.matches(host, rule: "*.example.com"))
    }
    #expect(ExternalLinkTrustedDomain.matches("example.com", rule: "example.com"))
    #expect(!ExternalLinkTrustedDomain.matches("sub.example.com", rule: "example.com"))
    #expect(ExternalLinkConfirmationPolicy.allLinks.requiresConfirmation(for: "sub.example.com", trustedDomains: ["*.example.com"]))
    #expect(!ExternalLinkConfirmationPolicy.noLinks.requiresConfirmation(for: "unknown.example", trustedDomains: []))
}
