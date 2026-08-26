import AppKit
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

@Test("About changelog loads regular and nightly releases in semantic order")
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

    func writeRelease(
        _ tagName: String,
        description: String,
        headline: String,
        emoji: String
    ) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "tagName": tagName,
            "githubDescription": description,
            "discordAnnouncement": "**\(headline) \(emoji)**\n\n**Highlights**\n- Test",
        ])
        try data.write(
            to: releases.appendingPathComponent("\(tagName).json")
        )
    }

    try writeRelease(
        "v0.1.3-Beta-1",
        description: "Newest beta notes",
        headline: "Newest beta",
        emoji: "🌙"
    )
    try writeRelease(
        "v0.1.2",
        description: "Current stable notes",
        headline: "Current stable",
        emoji: "🌸"
    )
    try writeRelease(
        "v0.1.2-Beta-10",
        description: "Tenth beta notes",
        headline: "Tenth beta",
        emoji: "🌙"
    )
    try writeRelease(
        "v0.1.2-Beta-2",
        description: "Second beta notes",
        headline: "Second beta",
        emoji: "🌙"
    )
    try writeRelease(
        "v0.1.1",
        description: "Backported notes",
        headline: "Backported release",
        emoji: "🌸"
    )
    try Data("Ignored".utf8).write(
        to: releases.appendingPathComponent("README.txt")
    )

    let notes = AboutResources.releaseNotes(resourceURL: directory)
    #expect(notes.map(\.tagName) == [
        "v0.1.3-Beta-1",
        "v0.1.2",
        "v0.1.2-Beta-10",
        "v0.1.2-Beta-2",
        "v0.1.1",
    ])
    #expect(notes.map(\.displayName) == [
        "v0.1.3 Beta 1",
        "v0.1.2",
        "v0.1.2 Beta 10",
        "v0.1.2 Beta 2",
        "v0.1.1",
    ])
    #expect(notes.map(\.releaseTrack) == [
        .nightly,
        .regular,
        .nightly,
        .nightly,
        .regular,
    ])
    #expect(notes.map(\.announcementHeadline) == [
        "Newest beta",
        "Current stable",
        "Tenth beta",
        "Second beta",
        "Backported release",
    ])
}

@Test("About Markdown rendering materializes native block and inline formatting")
@MainActor
func aboutMarkdownMaterializesNativeFormatting() {
    let document = AboutMarkdownRenderer.render(
        "# Heading\n\nParagraph with **bold**.\n\n- First\n- Second"
    )
    let rendered = AboutMarkdownAttributedText.make(document)

    #expect(document.runs.contains { $0.presentationIntent != nil })
    #expect(document.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    #expect(
        rendered.string
            == "Heading\nParagraph with bold.\n•\tFirst\n•\tSecond"
    )

    let headingFont = rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    let bodyIndex = (rendered.string as NSString).range(of: "Paragraph").location
    let bodyFont = rendered.attribute(.font, at: bodyIndex, effectiveRange: nil) as? NSFont
    #expect((headingFont?.pointSize ?? 0) > (bodyFont?.pointSize ?? 0))

    let boldIndex = (rendered.string as NSString).range(of: "bold").location
    let boldFont = rendered.attribute(.font, at: boldIndex, effectiveRange: nil) as? NSFont
    #expect(
        boldFont.map {
            NSFontManager.shared.traits(of: $0).contains(.boldFontMask)
        } == true
    )
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
