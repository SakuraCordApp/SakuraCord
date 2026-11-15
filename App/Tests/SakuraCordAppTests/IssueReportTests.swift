import Foundation
@testable import SakuraCord
import SakuraCordModels
import Testing

/// A trimmed copy of the hub's `/api/report/form` response.
private let reportFormJSON = """
{"versions":["0.1.6 Beta 4","0.1.5"],
 "kinds":{
  "bug":{"kind":"bug","title":"Report a bug","submitLabel":"Submit bug report","detailsLabel":"Add screenshots & system info",
   "titlePlaceholder":"e.g. Images never load","fields":[
    {"id":"what_happened","label":"What happened?","heading":"What happened?","kind":"paragraph","required":true,"maxLength":4000,"page":1},
    {"id":"impact","label":"How much does this affect you?","heading":"Impact","kind":"choice","required":true,
     "options":[{"value":"crash","label":"Crash","priority":"critical"},{"value":"minor","label":"Minor","priority":"low"}],"page":1},
    {"id":"version","label":"SakuraCord version","heading":"SakuraCord version","kind":"version","required":true,"page":1,"diagnostic":true},
    {"id":"attachments","label":"Screenshots or recordings","heading":"Screenshots or recordings","kind":"files","required":false,"page":2},
    {"id":"macos","label":"macOS version","heading":"macOS version","kind":"short","required":false,"page":2,"diagnostic":true},
    {"id":"mac","label":"Mac model","heading":"Mac model","kind":"short","required":false,"page":2,"diagnostic":true},
    {"id":"area","label":"Area","heading":"Area","kind":"area","required":false,"page":2},
    {"id":"extra","label":"Anything else?","heading":"Anything else?","kind":"paragraph","required":false,"maxLength":3000,"page":2},
    {"id":"rating","label":"Rating","heading":"Rating","kind":"stars","required":false,"page":2}]},
  "feature":{"kind":"feature","title":"Suggest a feature","submitLabel":"Submit suggestion","detailsLabel":"Add mockups & details",
   "titlePlaceholder":"e.g. Sounds","fields":[
    {"id":"request","label":"What would you like?","heading":"What would you like?","kind":"paragraph","required":true,"page":1},
    {"id":"version","label":"SakuraCord version","heading":"SakuraCord version","kind":"version","required":true,"page":1,"diagnostic":true}]},
  "future":{"kind":"future","title":"Ignored","submitLabel":"","detailsLabel":"","titlePlaceholder":"","fields":[]}},
 "meta":{"kinds":[],"statuses":[],"areas":[{"id":"chat","label":"Chat & Messages","emoji":"💬","description":"Messages","color":"#EF9BC4"}],"priorities":[]}}
"""

private func readyStore(kind: IssueReportKind = .bug) async throws -> IssueReportStore {
    let store = await IssueReportStore()
    let form = try JSONDecoder().decode(IssueReportForm.self, from: Data(reportFormJSON.utf8))
    await store.installFormForTesting(form, kind: kind)
    return store
}

@MainActor
@Test("an account reset during attachment preparation discards the old account's files")
func reportAttachmentAccountIsolation() async throws {
    let reports = IssueReportStore()
    let preferences = PrivacySafetySettingsStore(preferences: SettingsPreferenceStore(defaults: InMemoryPreferences()))
    var asked = false
    let privacy = UploadPrivacyPreparation(store: preferences) { _ in
        asked = true
        #expect(reports.pendingAttachmentLoads == 1)
        reports.reset()
        return true
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("private.svg")
    try Data("<svg xmlns=\"http://www.w3.org/2000/svg\"><metadata>Private</metadata></svg>".utf8).write(to: source)
    await reports.addAttachments([source], using: privacy)
    #expect(asked)
    #expect(reports.draft.attachments.isEmpty)
    #expect(reports.pendingAttachmentLoads == 0)
}

@MainActor
@Test("report schema decodes known kinds and matches release names like the hub")
func reportSchemaAndVersionMatching() throws {
    let form = try JSONDecoder().decode(IssueReportForm.self, from: Data(reportFormJSON.utf8))
    #expect(Set(form.kinds.keys) == [.bug, .feature])
    #expect(form.kinds[.bug]?.fields.last?.kind == .unsupported)
    #expect(form.supportedVersion(matching: "v0.1.6-Beta-4") == "0.1.6 Beta 4")
    #expect(form.supportedVersion(matching: "0.1.6  beta 4") == "0.1.6 Beta 4")
    #expect(form.supportedVersion(matching: "0.1.6 Beta 3") == nil)
    #expect(form.supportedVersion(matching: nil) == nil)
}

@MainActor
@Test("submission values carry exactly the schema's fields plus opted-in diagnostics")
func reportSubmissionValues() async throws {
    let store = try await readyStore()
    #expect(store.missingRequirement(before: .details) == "Add a short title.")
    store.setValue("Images never load", for: "title")
    #expect(store.missingRequirement(before: .details) == "Fill in “What happened?”.")
    store.setValue("Grey boxes", for: "what_happened")
    #expect(store.missingRequirement(before: .details) == "Choose an answer for “How much does this affect you?”.")
    store.setValue("minor", for: "impact")
    #expect(store.missingRequirement(before: .details) == nil)
    store.setValue("unexpected", for: "macos")

    // Unsupported builds must choose the supported release they retested on.
    if store.installedVersion == nil {
        #expect(store.missingRequirement(before: .done) == "Update SakuraCord to a supported release first.")
        store.setValue("0.1.5", for: "version")
    }
    #expect(store.missingRequirement(before: .done) == nil)

    var values = store.submissionValues()
    #expect(values["title"] == "Images never load")
    #expect(values["impact"] == "minor")
    #expect(values["version"] == store.selectedVersion)
    #expect(values["macos"] == store.systemInfo.macOS)
    #expect(values["area"] == nil)
    #expect(values["rating"] == nil)
    #expect(store.fields(on: 2).map(\.id) == ["attachments", "area", "extra"])

    store.draft.includesSystemInfo = false
    values = store.submissionValues()
    #expect(values["macos"] == nil && values["mac"] == nil)

    store.draft.includesAPILog = true
    store.draft.includesPanicSave = true
    #expect(store.uploadCount == 2)
    store.switchKind(to: .feature)
    #expect(store.uploadCount == 0)
}

@Test("oversized diagnostics keep their metadata line and the newest entries")
func diagnosticsTrimming() {
    let data = Data("header\none\ntwo\nthree\n".utf8)
    #expect(IssueReportDiagnostics.newestJSONLines(data, limit: 100) == data)
    #expect(String(decoding: IssueReportDiagnostics.newestJSONLines(data, limit: 18), as: UTF8.self)
        == "header\ntwo\nthree\n")
}

@MainActor
@Test("report links and built-in commands open the native flow")
func reportEntryPoints() throws {
    let bug = try #require(URL(string: "https://sakuracord.app/report?type=bug&version=0.1.5&macos=x"))
    #expect(SakuraCordDeepLinkPresentation.action(for: bug) == .startIssueReport(.bug))
    let feature = try #require(URL(string: "https://sakuracord.app/report?type=feature"))
    #expect(SakuraCordDeepLinkPresentation.action(for: feature) == .startIssueReport(.feature))
    let any = try #require(URL(string: "https://sakuracord.app/report"))
    #expect(SakuraCordDeepLinkPresentation.action(for: any) == .startIssueReport(nil))
    let other = try #require(URL(string: "https://example.com/report?type=bug"))
    #expect(SakuraCordDeepLinkPresentation.action(for: other) == nil)

    let composer = ApplicationCommandComposerModel()
    #expect(composer.commands.compactMap(SakuraCordBuiltInCommands.issueReportKind) == [.bug, .feature])
    #expect(!composer.hasLoadedCatalogs)
    let application = ApplicationCommandApplication(id: "100", name: "SakuraCord")
    let communityBot = ApplicationCommandApplication(id: AppModel.issueReportAuthorization.clientID, name: "SakuraCord")
    let foreignCommands = ["bug", "suggest", "report"].map { name in
        ApplicationCommand(
            id: "other:\(name)", rootCommandID: "other:\(name)", applicationID: application.id,
            version: "1", name: name, application: application
        )
    }
    let communityCommands = ["bug", "suggest", "roadmap"].map { name in
        ApplicationCommand(
            id: "community:\(name)", rootCommandID: "community:\(name)", applicationID: communityBot.id,
            version: "1", name: name, application: communityBot
        )
    }
    composer.replaceCatalogs([ApplicationCommandCatalog(
        target: .user, applications: [application, communityBot], commands: foreignCommands + communityCommands
    )])
    #expect(composer.hasLoadedCatalogs)
    #expect(composer.commands.map(\.id) == [
        "other:bug", "other:suggest", "other:report", "community:roadmap", "sakuracord:bug", "sakuracord:suggest"
    ])
    #expect(composer.sections(query: "bug").flatMap(\.commands).map(\.id).sorted() == ["other:bug", "sakuracord:bug"])
    #expect(foreignCommands.allSatisfy { SakuraCordBuiltInCommands.issueReportKind(for: $0) == nil })
    composer.resetForChannelChange()
    #expect(!composer.hasLoadedCatalogs)
    #expect(composer.commands.count == 2)
}
