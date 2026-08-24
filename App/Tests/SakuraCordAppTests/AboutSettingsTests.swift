import Foundation
import Testing
@testable import SakuraCord

@Test("About version information is sanitized stable and truthful when unavailable")
func aboutVersionInformationIsSanitized() {
    let available = AboutVersionInformation(
        infoDictionary: [
            "CFBundleShortVersionString": " 0.1.5-Beta+2 ",
            "CFBundleVersion": "42",
        ],
        releaseTrack: .nightly
    )
    #expect(available.semanticVersion == "0.1.5-Beta+2")
    #expect(available.buildNumber == "42")
    #expect(
        available.copyText
            == """
            SakuraCord Version Information
            Version: 0.1.5-Beta+2
            Build: 42
            Release track: Nightly
            """
    )

    let unavailable = AboutVersionInformation(
        infoDictionary: [
            "CFBundleShortVersionString": "0.1.5\ncredential",
            "CFBundleVersion": "",
        ],
        releaseTrack: .regular
    )
    #expect(unavailable.semanticVersion == nil)
    #expect(unavailable.buildNumber == nil)
    #expect(unavailable.semanticVersionDisplay == "Unavailable in this build")
    #expect(unavailable.copyText.contains("Version: Unavailable"))
}

@Test("About acknowledgements resolve only an existing packaged file")
func aboutAcknowledgementsRequirePackagedFile() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(AboutResources.acknowledgementsURL(resourceURL: directory) == nil)
    let notices = directory.appendingPathComponent(
        AboutResources.acknowledgementsFilename
    )
    try Data("Third-party notices".utf8).write(to: notices)
    #expect(
        AboutResources.acknowledgementsURL(resourceURL: directory) == notices
    )
}

@Test("About project destinations are canonical HTTPS links")
func aboutProjectDestinationsAreCanonical() {
    #expect(Set(AboutProjectLink.allCases.map(\.url)) == Set([
        URL(string: "https://sakuracord.app")!,
        URL(string: "https://github.com/SakuraCordApp/SakuraCord/tree/main/docs")!,
        URL(string: "https://roadmap.sakuracord.app")!,
        URL(string: "https://github.com/SakuraCordApp/SakuraCord")!,
        URL(string: "https://discord.gg/hWNwFXkUTP")!,
        URL(string: "https://github.com/SakuraCordApp/SakuraCord/releases/latest")!,
    ]))
    #expect(AboutProjectLink.allCases.allSatisfy {
        ExternalLinkSafetyPolicy.assess($0.url).isAllowed
    })
}

@MainActor
@Test("About catalog exposes each production control")
func aboutCatalogExposesProductionControls() {
    let expected: Set<SettingsControlID> = [
        .aboutVersionInformation,
        .aboutCopyVersionInformation,
        .aboutCheckForUpdates,
        .aboutWebsite,
        .aboutDocumentation,
        .aboutRoadmap,
        .aboutSource,
        .aboutSupport,
        .aboutLatestRelease,
        .aboutAcknowledgements,
        .aboutDisclaimer,
    ]
    let controls = SettingsCatalog.foundation.controls.filter {
        $0.destination.page == .about && expected.contains($0.id)
    }
    #expect(Set(controls.map(\.id)) == expected)
    #expect(controls.allSatisfy { $0.resetCapability == .notApplicable })
}
