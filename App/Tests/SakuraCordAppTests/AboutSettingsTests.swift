import Foundation
import Testing
@testable import SakuraCord

@Test("About version information is sanitized stable and truthful when unavailable")
func aboutVersionInformationIsSanitized() {
    let available = AboutVersionInformation(
        infoDictionary: [
            "CFBundleShortVersionString": " 0.1.5-Beta+2 ",
        ]
    )
    #expect(available.semanticVersion == "0.1.5-Beta+2")

    let unavailable = AboutVersionInformation(
        infoDictionary: [
            "CFBundleShortVersionString": "0.1.5\ncredential",
        ]
    )
    #expect(unavailable.semanticVersion == nil)
    #expect(unavailable.semanticVersionDisplay == "Unavailable in this build")
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
    try Data(
        """
        # Third-party notices

        ## First dependency

        First license.

        ### Nested license

        Nested details.

        ## Second asset

        Second notice.
        """.utf8
    ).write(to: notices)
    #expect(
        AboutResources.acknowledgementsURL(resourceURL: directory) == notices
    )
    #expect(
        AboutResources.acknowledgements(resourceURL: directory).map(\.title)
            == ["First dependency", "Second asset"]
    )
    #expect(
        AboutResources.acknowledgements(resourceURL: directory).map(\.markdown)
            == [
                "First license.\n\n### Nested license\n\nNested details.",
                "Second notice.",
            ]
    )
}

@Test("About changelog loads release records newest first")
func aboutChangelogLoadsPackagedReleaseNotes() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    let releases = directory.appendingPathComponent(
        AboutResources.releasesDirectoryName,
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: releases,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let current = releases.appendingPathComponent("v0.1.2.json")
    try Data(
        """
        {"schemaVersion":1,"tagName":"v0.1.2","githubDescription":"Current notes"}
        """.utf8
    ).write(to: current)
    let backport = releases.appendingPathComponent("v0.1.1.json")
    try Data(
        """
        {"schemaVersion":1,"tagName":"v0.1.1","githubDescription":"Backported notes"}
        """.utf8
    ).write(to: backport)
    try Data("Ignored".utf8).write(
        to: releases.appendingPathComponent("README.txt")
    )

    let notes = AboutResources.releaseNotes(resourceURL: directory)
    #expect(notes.map(\.tagName) == ["v0.1.2", "v0.1.1"])
    #expect(notes.map(\.githubDescription) == ["Current notes", "Backported notes"])
}

@Test("About project destinations are canonical HTTPS links")
func aboutProjectDestinationsAreCanonical() {
    #expect(Set(AboutProjectLink.allCases.map(\.url)) == Set([
        URL(string: "https://sakuracord.app")!,
        URL(string: "https://roadmap.sakuracord.app")!,
        URL(string: "https://github.com/SakuraCordApp/SakuraCord")!,
        URL(string: "https://discord.gg/hWNwFXkUTP")!,
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
        .aboutCheckForUpdates,
        .aboutChangelog,
        .aboutWebsite,
        .aboutRoadmap,
        .aboutSource,
        .aboutSupport,
        .aboutAcknowledgements,
        .aboutDisclaimer,
    ]
    let controls = SettingsCatalog.foundation.controls.filter {
        $0.destination.page == .about && expected.contains($0.id)
    }
    #expect(Set(controls.map(\.id)) == expected)
    #expect(controls.allSatisfy { $0.resetCapability == .notApplicable })
}
