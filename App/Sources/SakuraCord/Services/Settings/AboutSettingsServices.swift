import Foundation

nonisolated struct AboutVersionInformation: Equatable, Sendable {
    let semanticVersion: String?

    init(infoDictionary: [String: Any]) {
        semanticVersion = Self.sanitizedBundleValue(
            infoDictionary["CFBundleShortVersionString"]
        )
    }

    init(bundle: Bundle = .main) {
        self.init(infoDictionary: bundle.infoDictionary ?? [:])
    }

    var semanticVersionDisplay: String {
        semanticVersion ?? "Unavailable in this build"
    }

    private static func sanitizedBundleValue(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: ".+-_")
        )
        guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else {
            return nil
        }
        return trimmed
    }
}

nonisolated struct AboutReleaseNotes: Decodable, Equatable, Identifiable, Sendable {
    let schemaVersion: Int
    let tagName: String
    let githubDescription: String

    var id: String { tagName }
}

nonisolated struct AboutAcknowledgement: Equatable, Identifiable, Sendable {
    let title: String
    let markdown: String

    var id: String { title }
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
            .sorted {
                $0.tagName.localizedStandardCompare($1.tagName) == .orderedDescending
            }
    }

    private static func releaseNotes(
        at url: URL,
        fileManager: FileManager
    ) -> AboutReleaseNotes? {
        guard let data = fileManager.contents(atPath: url.path),
              let notes = try? JSONDecoder().decode(AboutReleaseNotes.self, from: data),
              notes.schemaVersion == 1,
              notes.tagName.hasPrefix("v"),
              !notes.githubDescription.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty
        else { return nil }
        return notes
    }
}
