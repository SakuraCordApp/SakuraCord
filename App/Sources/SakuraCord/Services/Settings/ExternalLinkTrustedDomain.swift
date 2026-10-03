import Foundation

nonisolated enum ExternalLinkTrustedDomain {
    static let defaults: [String] = {
        guard let url = #bundle.url(forResource: "trusted-domains", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let domains = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return normalizedList(domains)
    }()

    static func normalized(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("*.") {
            let suffix = String(trimmed.dropFirst(2))
            guard !suffix.contains("://"), !suffix.contains("/"),
                  let host = normalizedHost(suffix),
                  !host.split(separator: ".").allSatisfy({ $0.allSatisfy(\.isNumber) }),
                  let publicSuffixes, !publicSuffixes.contains(host)
            else { return nil }
            return "*.\(host)"
        }
        return normalizedHost(trimmed)
    }

    static func matches(_ domain: String, rule: String) -> Bool {
        guard let host = normalizedHost(domain), let rule = normalized(rule) else { return false }
        if rule.hasPrefix("*.") {
            return host.hasSuffix(String(rule.dropFirst()))
        }
        return host == rule
    }

    static func normalizedList(_ domains: [String]) -> [String] {
        Array(Set(domains.compactMap(normalized))).sorted()
    }

    private static func normalizedHost(_ input: String) -> String? {
        guard !input.isEmpty else { return nil }
        let candidate = input.contains("://") ? input : "https://\(input)"
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

    private static let publicSuffixes: PublicSuffixRules? = {
        guard let url = #bundle.url(forResource: "public-suffix-list", withExtension: "dat"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        let rules = PublicSuffixRules(text)
        guard rules.contains("com"), rules.contains("github.io") else { return nil }
        return rules
    }()
}

/// Both ICANN and private rules prevent trusting an entire registry or shared host.
nonisolated private struct PublicSuffixRules: Sendable {
    private var exact: Set<String> = []
    private var wildcard: Set<String> = []
    private var exceptions: Set<String> = []

    init(_ text: String) {
        for line in text.split(whereSeparator: \.isNewline) {
            let rule = line.trimmingCharacters(in: .whitespaces)
            guard !rule.isEmpty, !rule.hasPrefix("//") else { continue }
            let isException = rule.hasPrefix("!")
            let isWildcard = rule.hasPrefix("*.")
            let name = isException ? String(rule.dropFirst())
                : isWildcard ? String(rule.dropFirst(2)) : rule
            // The PSL is UTF-8; URL.host() converts its IDN rules to ASCII.
            guard let host = URL(string: "https://\(name)")?.host()?.lowercased() else { continue }
            if isException {
                exceptions.insert(host)
            } else if isWildcard {
                wildcard.insert(host)
            } else {
                exact.insert(host)
            }
        }
    }

    func contains(_ host: String) -> Bool {
        if exceptions.contains(host) { return false }
        if exact.contains(host) || wildcard.contains(host) { return true }
        let labels = host.split(separator: ".")
        return labels.count == 1 || wildcard.contains(labels.dropFirst().joined(separator: "."))
    }
}
