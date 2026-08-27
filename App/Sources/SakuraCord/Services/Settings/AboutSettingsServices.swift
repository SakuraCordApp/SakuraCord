import Foundation

nonisolated struct AboutVersionInformation: Equatable, Sendable {
    let semanticVersion: String?
    let displayVersion: String?

    init(infoDictionary: [String: Any]) {
        semanticVersion = Self.sanitizedBundleValue(
            infoDictionary["CFBundleShortVersionString"],
            allowsSpaces: false
        )
        displayVersion = Self.sanitizedBundleValue(
            infoDictionary["SakuraCordReleaseDisplayVersion"],
            allowsSpaces: true
        ) ?? semanticVersion
    }

    init(bundle: Bundle = .main) {
        self.init(infoDictionary: bundle.infoDictionary ?? [:])
    }

    var semanticVersionDisplay: String {
        displayVersion ?? "Unavailable in this build"
    }

    var prefixedDisplay: String {
        displayVersion.map { "v\($0)" } ?? semanticVersionDisplay
    }

    private static func sanitizedBundleValue(
        _ value: Any?,
        allowsSpaces: Bool
    ) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return nil }
        var allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: ".+-_")
        )
        if allowsSpaces {
            allowed.insert(charactersIn: " ")
        }
        guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else {
            return nil
        }
        return trimmed
    }
}

nonisolated struct AboutReleaseVersion: Comparable, Equatable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int
    let beta: Int?

    init?(tagName: String) {
        guard tagName.hasPrefix("v") else { return nil }
        let tagComponents = tagName.dropFirst().split(
            separator: "-",
            omittingEmptySubsequences: false
        )
        guard tagComponents.count == 1 || (
            tagComponents.count == 3
                && tagComponents[1] == "Beta"
                && Int(tagComponents[2]) != nil
        ) else { return nil }

        let versionComponents = tagComponents[0].split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard versionComponents.count == 3,
              let major = Int(versionComponents[0]),
              let minor = Int(versionComponents[1]),
              let patch = Int(versionComponents[2])
        else { return nil }

        self.major = major
        self.minor = minor
        self.patch = patch
        beta = tagComponents.count == 3 ? Int(tagComponents[2]) : nil
    }

    var releaseTrack: AppUpdateReleaseTrack {
        beta == nil ? .regular : .nightly
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        let lhsVersion = (lhs.major, lhs.minor, lhs.patch)
        let rhsVersion = (rhs.major, rhs.minor, rhs.patch)
        if lhsVersion != rhsVersion {
            return lhsVersion < rhsVersion
        }
        return switch (lhs.beta, rhs.beta) {
        case (nil, nil): false
        case (nil, _): false
        case (_, nil): true
        case let (lhsBeta?, rhsBeta?): lhsBeta < rhsBeta
        }
    }
}

nonisolated struct AboutReleaseNotes: Decodable, Equatable, Identifiable, Sendable {
    let schemaVersion: Int
    let tagName: String
    let githubDescription: String
    let discordAnnouncement: String
    let releaseVersion: AboutReleaseVersion
    let announcementHeadline: String
    let renderedGithubDescription: AttributedString

    var id: String { tagName }

    var displayName: String {
        tagName.replacingOccurrences(of: "-Beta-", with: " Beta ")
    }

    var releaseTrack: AppUpdateReleaseTrack {
        releaseVersion.releaseTrack
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case tagName
        case githubDescription
        case discordAnnouncement
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        tagName = try container.decode(String.self, forKey: .tagName)
        githubDescription = try container.decode(String.self, forKey: .githubDescription)
        discordAnnouncement = try container.decode(String.self, forKey: .discordAnnouncement)

        guard schemaVersion == 1,
              let releaseVersion = AboutReleaseVersion(tagName: tagName),
              !githubDescription.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty,
              let announcementHeadline = Self.headline(
                  in: discordAnnouncement,
                  releaseTrack: releaseVersion.releaseTrack
              )
        else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid SakuraCord release notes."
                )
            )
        }

        self.releaseVersion = releaseVersion
        self.announcementHeadline = announcementHeadline
        renderedGithubDescription = AboutMarkdownRenderer.render(githubDescription)
    }

    private static func headline(
        in announcement: String,
        releaseTrack: AppUpdateReleaseTrack
    ) -> String? {
        guard var headline = announcement.split(
            separator: "\n",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first.map(String.init),
            headline.hasPrefix("**"),
            headline.hasSuffix("**")
        else { return nil }

        headline.removeFirst(2)
        headline.removeLast(2)
        let emoji = releaseTrack == .nightly ? "🌙" : "🌸"
        guard headline.hasSuffix(emoji) else { return nil }
        headline.removeLast(emoji.count)
        let value = headline.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

nonisolated struct AboutAcknowledgement: Equatable, Identifiable, Sendable {
    let title: String
    let markdown: String
    let renderedMarkdown: AttributedString

    var id: String { title }

    init(title: String, markdown: String) {
        self.title = title
        self.markdown = markdown
        renderedMarkdown = AboutMarkdownRenderer.render(markdown)
    }
}

nonisolated enum AboutMarkdownRenderer {
    static func render(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: markdown, options: options))
            ?? AttributedString(markdown)
    }
}

nonisolated enum AboutProjectLink: String, CaseIterable, Identifiable, Sendable {
    case website = "https://sakuracord.app"
    case roadmap = "https://roadmap.sakuracord.app"
    case source = "https://github.com/SakuraCordApp/SakuraCord"
    case support = "https://discord.gg/hWNwFXkUTP"

    var id: Self { self }

    var url: URL { URL(string: rawValue)! }

    var title: LocalizedStringResource {
        switch self {
        case .website: LocalizedStringResource("Website", bundle: #bundle)
        case .roadmap: LocalizedStringResource("Roadmap", bundle: #bundle)
        case .source: LocalizedStringResource("Source", bundle: #bundle)
        case .support: LocalizedStringResource("Discord", bundle: #bundle)
        }
    }

    var controlID: SettingsControlID {
        switch self {
        case .website: .aboutWebsite
        case .roadmap: .aboutRoadmap
        case .source: .aboutSource
        case .support: .aboutSupport
        }
    }
}

nonisolated enum AboutResources {
    static let acknowledgementsFilename = "THIRD_PARTY_NOTICES.md"
    static let releasesDirectoryName = "Releases"

    static let packagedAcknowledgements = acknowledgements(
        resourceURL: Bundle.main.resourceURL
    )
    static let packagedReleaseNotes = releaseNotes(
        resourceURL: Bundle.main.resourceURL
    )

    static func acknowledgementsURL(
        resourceURL: URL?,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let candidate = resourceURL?.appendingPathComponent(
            acknowledgementsFilename,
            isDirectory: false
        ) else { return nil }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: candidate.path,
            isDirectory: &isDirectory
        ), !isDirectory.boolValue else { return nil }
        return candidate
    }

    static func acknowledgementsText(
        resourceURL: URL?,
        fileManager: FileManager = .default
    ) -> String? {
        guard let url = acknowledgementsURL(
            resourceURL: resourceURL,
            fileManager: fileManager
        ), let data = fileManager.contents(atPath: url.path)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func acknowledgements(
        resourceURL: URL?,
        fileManager: FileManager = .default
    ) -> [AboutAcknowledgement] {
        guard let markdown = acknowledgementsText(
            resourceURL: resourceURL,
            fileManager: fileManager
        ) else { return [] }
        return acknowledgements(markdown: markdown)
    }

    static func acknowledgements(markdown: String) -> [AboutAcknowledgement] {
        var values: [AboutAcknowledgement] = []
        var currentTitle: String?
        var currentBody: [String] = []

        func appendCurrentSection() {
            guard let currentTitle else { return }
            let body = currentBody.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return }
            values.append(
                AboutAcknowledgement(title: currentTitle, markdown: body)
            )
        }

        for line in markdown.components(separatedBy: .newlines) {
            if line.hasPrefix("## "), !line.hasPrefix("### ") {
                appendCurrentSection()
                currentTitle = String(line.dropFirst(3))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                currentBody.removeAll(keepingCapacity: true)
            } else if currentTitle != nil {
                currentBody.append(line)
            }
        }
        appendCurrentSection()
        return values
    }

    static func releaseNotes(
        resourceURL: URL?,
        fileManager: FileManager = .default
    ) -> [AboutReleaseNotes] {
        guard let directory = resourceURL?.appendingPathComponent(
            releasesDirectoryName,
            isDirectory: true
        ), let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return files
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { releaseNotes(at: $0, fileManager: fileManager) }
            .sorted { $0.releaseVersion > $1.releaseVersion }
    }

    private static func releaseNotes(
        at url: URL,
        fileManager: FileManager
    ) -> AboutReleaseNotes? {
        guard let data = fileManager.contents(atPath: url.path) else { return nil }
        return try? JSONDecoder().decode(AboutReleaseNotes.self, from: data)
    }
}
