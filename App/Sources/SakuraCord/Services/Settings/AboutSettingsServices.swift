import Foundation

nonisolated struct AboutVersionInformation: Equatable, Sendable {
    static let unavailableValue = "Unavailable"

    let semanticVersion: String?
    let buildNumber: String?
    let releaseTrack: AppUpdateReleaseTrack

    init(
        infoDictionary: [String: Any],
        releaseTrack: AppUpdateReleaseTrack
    ) {
        semanticVersion = Self.sanitizedBundleValue(
            infoDictionary["CFBundleShortVersionString"]
        )
        buildNumber = Self.sanitizedBundleValue(
            infoDictionary["CFBundleVersion"]
        )
        self.releaseTrack = releaseTrack
    }

    init(
        bundle: Bundle = .main,
        releaseTrack: AppUpdateReleaseTrack
    ) {
        self.init(
            infoDictionary: bundle.infoDictionary ?? [:],
            releaseTrack: releaseTrack
        )
    }

    var semanticVersionDisplay: String {
        semanticVersion ?? "Unavailable in this build"
    }

    var buildNumberDisplay: String {
        buildNumber ?? "Unavailable in this build"
    }

    var copyText: String {
        """
        SakuraCord Version Information
        Version: \(semanticVersion ?? Self.unavailableValue)
        Build: \(buildNumber ?? Self.unavailableValue)
        Release track: \(releaseTrack.title)
        """
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

nonisolated enum AboutProjectLink: String, CaseIterable, Identifiable, Sendable {
    case website = "https://sakuracord.app"
    case documentation = "https://github.com/SakuraCordApp/SakuraCord/tree/main/docs"
    case roadmap = "https://roadmap.sakuracord.app"
    case source = "https://github.com/SakuraCordApp/SakuraCord"
    case support = "https://discord.gg/hWNwFXkUTP"
    case latestRelease = "https://github.com/SakuraCordApp/SakuraCord/releases/latest"

    var id: Self { self }

    var url: URL { URL(string: rawValue)! }

    var title: LocalizedStringResource {
        switch self {
        case .website: LocalizedStringResource("Project Website", bundle: #bundle)
        case .documentation: LocalizedStringResource("Documentation", bundle: #bundle)
        case .roadmap: LocalizedStringResource("Roadmap", bundle: #bundle)
        case .source: LocalizedStringResource("Source Repository", bundle: #bundle)
        case .support: LocalizedStringResource("Support Community", bundle: #bundle)
        case .latestRelease: LocalizedStringResource("Latest Release", bundle: #bundle)
        }
    }

    var systemImage: String {
        switch self {
        case .website: "globe"
        case .documentation: "book.closed"
        case .roadmap: "map"
        case .source: "chevron.left.forwardslash.chevron.right"
        case .support: "person.3"
        case .latestRelease: "shippingbox"
        }
    }

    var controlID: SettingsControlID {
        switch self {
        case .website: .aboutWebsite
        case .documentation: .aboutDocumentation
        case .roadmap: .aboutRoadmap
        case .source: .aboutSource
        case .support: .aboutSupport
        case .latestRelease: .aboutLatestRelease
        }
    }
}

nonisolated enum AboutResources {
    static let acknowledgementsFilename = "THIRD_PARTY_NOTICES.md"

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
}
