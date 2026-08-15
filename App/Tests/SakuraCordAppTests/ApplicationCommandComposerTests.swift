import AppKit
import Foundation
@testable import SakuraCord
import SakuraCordModels
import Testing

private func composerFixtureCommand(
    id: String,
    name: String,
    application: ApplicationCommandApplication,
    description: String = "",
    rank: Int? = nil,
    options: [ApplicationCommandOption] = []
) -> ApplicationCommand {
    ApplicationCommand(
        id: id, rootCommandID: id, applicationID: application.id, version: "1",
        name: name, description: description, application: application,
        options: options, globalPopularityRank: rank,
        rootCommandJSON: Data(
            "{\"id\":\"\(id)\",\"application_id\":\"\(application.id)\",\"name\":\"\(name)\"}"
                .utf8
        )
    )
}

@MainActor
@Test("command search ranks exact prefix fuzzy and application matches deterministically")
func commandSearchRanking() throws {
    let model = ApplicationCommandComposerModel()
    let verified = ApplicationCommandApplication(id: "100", name: "Verified")
    let utility = ApplicationCommandApplication(id: "101", name: "Utility")
    let exact = composerFixtureCommand(
        id: "200", name: "verify", application: verified, description: "Verify a member", rank: 8
    )
    let prefix = composerFixtureCommand(
        id: "201", name: "verifyforme", application: verified, rank: 1
    )
    let fuzzy = composerFixtureCommand(
        id: "202", name: "very-safe", application: utility, rank: 2
    )
    model.beginLoading(targets: [.user])
    model.replaceCatalogs([
        ApplicationCommandCatalog(
            target: .user, applications: [verified, utility], commands: [fuzzy, prefix, exact]
        )
    ])

    #expect(model.rankedCommands(query: "verify").map(\.id) == ["200", "201"])
    #expect(model.rankedCommands(query: "vys").map(\.id) == ["202"])
    #expect(model.rankedCommands(query: "utility").map(\.id) == ["202"])
    #expect(model.sections(query: "verify").flatMap(\.commands).map(\.id) == ["200", "201"])
}

@MainActor
@Test("required and optional command options keep stable typed values")
func commandOptionEditing() throws {
    let model = ApplicationCommandComposerModel()
    let application = ApplicationCommandApplication(id: "100", name: "Utility")
    let required = ApplicationCommandOption(
        id: "200/text", name: "text", type: .string, isRequired: true
    )
    let optional = ApplicationCommandOption(
        id: "200/file", name: "file", type: .attachment
    )
    let command = composerFixtureCommand(
        id: "200", name: "sayas", application: application, options: [required, optional]
    )
    model.replaceCatalogs([
        ApplicationCommandCatalog(
            target: .user, applications: [application], commands: [command]
        )
    ])
    model.activate(command)

    #expect(model.displayedOptions.map(\.id) == [required.id])
    #expect(!model.canSubmit)
    model.setValue(.string("hello"), for: required)
    model.addOptionalOption(optional)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
        "sakuracord-command-option-test.txt"
    )
    try Data("attachment".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    model.setValue(.attachment(file), for: optional)
    #expect(model.displayedOptions.map(\.id) == [required.id, optional.id])
    #expect(model.canSubmit)

    let invocation = try #require(
        model.invocation(channelID: ChannelID("300")!, guildID: GuildID("400")!)
    )
    #expect(invocation.values.map(\.optionID) == [required.id, optional.id])
    #expect(invocation.values.last?.argument == .attachment(file))

    model.removeOptionalOption(optional)
    #expect(model.value(for: optional) == nil)
    #expect(model.displayedOptions.map(\.id) == [required.id])
    #expect(model.focusedOption == nil)

    model.clearValue(for: required)
    #expect(model.value(for: required) == nil)
    #expect(model.draftText(for: required).isEmpty)
    #expect(model.focusedOptionID == required.id)
}

@MainActor
@Test("minimum integer validation fails safely without overflowing")
func minimumIntegerValidationDoesNotTrap() {
    let model = ApplicationCommandComposerModel()
    let application = ApplicationCommandApplication(id: "100", name: "Utility")
    let option = ApplicationCommandOption(
        name: "count", type: .integer, isRequired: true
    )
    let command = composerFixtureCommand(
        id: "200", name: "count", application: application, options: [option]
    )
    model.activate(command)
    model.setValue(.integer(.min), for: option)

    #expect(model.validationError(for: option) == "This number is outside Discord's safe integer range.")
    #expect(!model.canSubmit)
}

@MainActor
@Test("autocomplete and interaction events ignore stale nonces")
func commandLifecycleNonceScoping() throws {
    let model = ApplicationCommandComposerModel()
    let application = ApplicationCommandApplication(id: "100", name: "Utility")
    let option = ApplicationCommandOption(
        id: "200/query", name: "query", type: .string, isRequired: true,
        usesAutocomplete: true
    )
    let command = composerFixtureCommand(
        id: "200", name: "search", application: application, options: [option]
    )
    model.activate(command)
    #expect(model.prepareAutocomplete(option: option, query: "sa", nonce: "one") == .request)
    #expect(model.prepareAutocomplete(option: option, query: "sa", nonce: "duplicate") == .pending)
    #expect(model.autocompleteNonce == "one")
    model.receiveAutocomplete(
        ApplicationCommandAutocompleteResult(
            nonce: "old", choices: [.init(name: "Old", value: .string("old"))]
        )
    )
    #expect(model.autocompleteChoices.isEmpty)
    model.receiveAutocomplete(
        ApplicationCommandAutocompleteResult(
            nonce: "one", choices: [.init(name: "Sakura", value: .string("sakura"))]
        )
    )
    #expect(model.autocompleteChoices.map(\.name) == ["Sakura"])
    #expect(model.prepareAutocomplete(option: option, query: "sa", nonce: "cached") == .cached)
    #expect(model.autocompleteChoices.map(\.name) == ["Sakura"])
    #expect(!model.isAutocompleteLoading)
    #expect(model.prepareAutocomplete(option: option, query: "new", nonce: "two") == .request)
    model.leaveOptionFocus()
    #expect(model.autocompleteNonce == nil)
    #expect(model.autocompleteChoices.isEmpty)

    model.updateExecutionProgress(.submitting(nonce: "execution"))
    model.interactionCreated(nonce: "other", interactionID: "900")
    #expect(model.executionState == .queued(nonce: "execution"))
    model.interactionCreated(nonce: "execution", interactionID: "901")
    #expect(model.executionState == .created(nonce: "execution", interactionID: "901"))
    #expect(model.interactionFailed(nonce: "execution", message: "Rejected"))
    #expect(model.executionState == .failed(nonce: "execution", message: "Rejected"))
}

@MainActor
@Test("superseded autocomplete failures remain scoped to autocomplete")
func supersededAutocompleteFailureScoping() {
    let model = ApplicationCommandComposerModel()
    let application = ApplicationCommandApplication(id: "100", name: "Utility")
    let option = ApplicationCommandOption(
        id: "200/query", name: "query", type: .string, isRequired: true,
        usesAutocomplete: true
    )
    let command = composerFixtureCommand(
        id: "200", name: "search", application: application, options: [option]
    )
    model.activate(command)
    #expect(model.prepareAutocomplete(option: option, query: "sa", nonce: "stale") == .request)
    model.leaveOptionFocus()

    #expect(model.interactionFailed(nonce: "stale", message: "Timed out"))
    #expect(model.autocompleteError == nil)
    #expect(model.executionError == nil)
    #expect(!model.interactionFailed(nonce: "unrelated", message: "Rejected"))
}

@MainActor
@Test("command availability respects context and explicit permission precedence")
func commandAvailabilityFiltering() throws {
    let application = ApplicationCommandApplication(id: "100", name: "Utility")
    let userID = try #require(UserID("500"))
    let guildID = try #require(GuildID("600"))
    let channelID = try #require(ChannelID("700"))
    let roleID = try #require(RoleID("800"))
    let channel = Channel(id: channelID, guildID: guildID, name: "general")
    var command = composerFixtureCommand(id: "200", name: "verify", application: application)
    command.contexts = [0]
    command.permissions = [
        .init(id: guildID.description, type: 1, allows: false),
        .init(id: roleID.description, type: 1, allows: true),
        .init(id: userID.description, type: 2, allows: false)
    ]

    #expect(!ApplicationCommandAvailability.isAvailable(
        command, channel: channel, currentUserID: userID, memberRoleIDs: [roleID]
    ))
    command.permissions.removeAll { $0.type == 2 }
    #expect(ApplicationCommandAvailability.isAvailable(
        command, channel: channel, currentUserID: userID, memberRoleIDs: [roleID]
    ))
    command.contexts = [1, 2]
    #expect(!ApplicationCommandAvailability.isAvailable(
        command, channel: channel, currentUserID: userID, memberRoleIDs: [roleID]
    ))
    command.contexts = [0]
    command.integrationTypes = [1]
    #expect(!ApplicationCommandAvailability.isAvailable(
        command, channel: channel, currentUserID: userID, memberRoleIDs: [roleID],
        indexTarget: .guild(guildID)
    ))
    #expect(ApplicationCommandAvailability.isAvailable(
        command, channel: channel, currentUserID: userID, memberRoleIDs: [roleID],
        indexTarget: .user
    ))
}

@MainActor
@Test("command availability distinguishes bot DMs from private channels")
func commandDirectMessageContextFiltering() {
    let bot = User(
        id: UserID(rawValue: 501), username: "utility", displayName: "Utility", isBot: true
    )
    let person = User(
        id: UserID(rawValue: 502), username: "person", displayName: "Person"
    )
    let application = ApplicationCommandApplication(id: "100", name: "Utility", bot: bot)
    var command = composerFixtureCommand(id: "200", name: "verify", application: application)
    let botDM = Channel(
        id: ChannelID(rawValue: 700), guildID: nil, name: "Utility",
        kind: .directMessage, recipients: [bot]
    )
    let privateDM = Channel(
        id: ChannelID(rawValue: 701), guildID: nil, name: "Person",
        kind: .directMessage, recipients: [person]
    )
    let groupDM = Channel(
        id: ChannelID(rawValue: 702), guildID: nil, name: "Group",
        kind: .groupDirectMessage, recipients: [bot, person]
    )

    command.contexts = [1]
    #expect(ApplicationCommandAvailability.isAvailable(
        command, channel: botDM, currentUserID: nil, memberRoleIDs: []
    ))
    #expect(!ApplicationCommandAvailability.isAvailable(
        command, channel: privateDM, currentUserID: nil, memberRoleIDs: []
    ))
    #expect(!ApplicationCommandAvailability.isAvailable(
        command, channel: groupDM, currentUserID: nil, memberRoleIDs: []
    ))

    command.contexts = [2]
    #expect(!ApplicationCommandAvailability.isAvailable(
        command, channel: botDM, currentUserID: nil, memberRoleIDs: []
    ))
    #expect(ApplicationCommandAvailability.isAvailable(
        command, channel: privateDM, currentUserID: nil, memberRoleIDs: []
    ))
    #expect(ApplicationCommandAvailability.isAvailable(
        command, channel: groupDM, currentUserID: nil, memberRoleIDs: []
    ))
}

@MainActor
@Test("pending invocation enriches a type 20 message before the editor closes")
func interactionResponseReconciliation() throws {
    let model = ApplicationCommandComposerModel()
    let app = ApplicationCommandApplication(id: "100", name: "Verified")
    let command = composerFixtureCommand(id: "200", name: "verify", application: app)
    model.activate(command)
    model.updateExecutionProgress(.submitting(nonce: "900"))
    model.interactionSucceeded(nonce: "900")
    let currentUser = User(
        id: try #require(UserID("500")), username: "tester", displayName: "Tester"
    )
    var message = Message(
        id: try #require(MessageID("901")),
        channelID: try #require(ChannelID("700")),
        author: User(
            id: try #require(UserID("100")), username: "verified", displayName: "Verified",
            isBot: true
        ),
        content: "Done", nonce: "900", type: .chatInputCommand
    )

    model.enrichInteractionResponse(&message, currentUser: currentUser)
    #expect(message.interactionMetadata?.displayName == "verify")
    #expect(message.interactionMetadata?.user == currentUser)
    #expect(message.interactionMetadata?.applicationID == "100")
}

@MainActor
@Test("inline command fields preserve drafts values and arrow navigation")
func inlineCommandFieldEditing() throws {
    let model = ApplicationCommandComposerModel()
    let application = ApplicationCommandApplication(id: "100", name: "Utility")
    let first = ApplicationCommandOption(
        id: "200/first", name: "first", type: .string, isRequired: true
    )
    let second = ApplicationCommandOption(
        id: "200/second", name: "second", type: .integer, isRequired: true
    )
    let optional = ApplicationCommandOption(
        id: "200/optional", name: "optional", type: .string
    )
    let command = composerFixtureCommand(
        id: "200", name: "inline", application: application,
        options: [first, second, optional]
    )
    model.activate(command)

    model.updateDraftText("hello", for: first)
    #expect(model.value(for: first) == .string("hello"))
    #expect(model.draftText(for: first) == "hello")
    model.moveOptionFocus(by: 1)
    #expect(model.focusedOptionID == second.id)
    model.updateDraftText("42", for: second)
    #expect(model.value(for: second) == .integer(42))
    model.moveOptionFocus(by: 1)
    #expect(model.focusedOptionID == nil)
    #expect(model.displayedOptions.map(\.id) == [first.id, second.id])
    model.moveOptionFocus(by: -1)
    #expect(model.focusedOptionID == second.id)
    model.moveOptionFocus(by: 1)
    #expect(model.focusedOptionID == nil)
    model.addOptionalOption(optional)
    #expect(model.focusedOptionID == optional.id)
    #expect(model.displayedOptions.map(\.id) == [first.id, second.id, optional.id])
    model.moveOptionFocus(by: -1)
    #expect(model.focusedOptionID == second.id)
    #expect(model.draftText(for: first) == "hello")
}

@MainActor
@Test("optional command fields stay in the order the user adds them")
func optionalCommandFieldsUseInsertionOrder() {
    let model = ApplicationCommandComposerModel()
    let application = ApplicationCommandApplication(id: "100", name: "Utility")
    let required = ApplicationCommandOption(
        id: "200/required", name: "required", type: .string, isRequired: true
    )
    let firstInSchema = ApplicationCommandOption(
        id: "200/first", name: "first", type: .string
    )
    let secondInSchema = ApplicationCommandOption(
        id: "200/second", name: "second", type: .string
    )
    let command = composerFixtureCommand(
        id: "200", name: "order", application: application,
        options: [required, firstInSchema, secondInSchema]
    )
    model.activate(command)

    model.addOptionalOption(secondInSchema)
    model.addOptionalOption(firstInSchema)

    #expect(model.displayedOptions.map(\.id) == [
        required.id, secondInSchema.id, firstInSchema.id
    ])
    model.removeOptionalOption(secondInSchema)
    model.addOptionalOption(secondInSchema)
    #expect(model.displayedOptions.map(\.id) == [
        required.id, firstInSchema.id, secondInSchema.id
    ])
}

@MainActor
@Test("commands with only optional fields begin outside a field")
func optionalOnlyCommandStartsWithFieldChooser() {
    let model = ApplicationCommandComposerModel()
    let application = ApplicationCommandApplication(id: "100", name: "Utility")
    let optional = ApplicationCommandOption(
        id: "200/optional", name: "optional", type: .string
    )
    let command = composerFixtureCommand(
        id: "200", name: "optional", application: application, options: [optional]
    )

    model.activate(command)

    #expect(model.focusedOptionID == nil)
    #expect(model.displayedOptions.isEmpty)
    #expect(model.availableOptionalOptions.map(\.id) == [optional.id])
}

@MainActor
@Test("command suggestions never mix field values with optional fields")
func commandSuggestionContextSeparation() throws {
    let active = ApplicationCommandOption(
        id: "200/enabled", name: "enabled", type: .boolean, isRequired: true
    )
    let optional = ApplicationCommandOption(
        id: "200/note", name: "note", description: "Optional note", type: .string
    )
    let genericOptional = ApplicationCommandOption(
        id: "200/role", name: "role", description: "Role", type: .role
    )

    let fieldSuggestions = ApplicationCommandSuggestionFactory.suggestions(
        option: active,
        query: "",
        members: [],
        roles: [],
        channels: [],
        autocompleteChoices: [],
        availableOptions: [optional]
    )
    #expect(fieldSuggestions.map(\.title) == ["True", "False"])
    #expect(fieldSuggestions.allSatisfy {
        if case .addOption = $0.action { return false }
        return true
    })

    let outsideSuggestions = ApplicationCommandSuggestionFactory.suggestions(
        option: nil,
        query: "",
        members: [],
        roles: [],
        channels: [],
        autocompleteChoices: [],
        availableOptions: [optional, genericOptional]
    )
    #expect(outsideSuggestions.map(\.title) == ["note", "role"])
    let suggestion = try #require(outsideSuggestions.first)
    #expect(suggestion.trailingText == "Optional note")
    #expect(outsideSuggestions.last?.trailingText == nil)
    guard case let .addOption(value) = suggestion.action else {
        Issue.record("Expected the outside-field panel to offer an optional field")
        return
    }
    #expect(value.id == optional.id)
}

@MainActor
@Test("role command suggestions use the full guild role catalog")
func commandSuggestionUsesGuildRoles() throws {
    let option = ApplicationCommandOption(
        id: "200/role", name: "role", type: .role, isRequired: true
    )
    let unassigned = GuildRole(
        id: try #require(RoleID("900")), name: "Unassigned role", position: 10,
        colorHex: 0xB45CFF
    )

    let suggestions = ApplicationCommandSuggestionFactory.suggestions(
        option: option,
        query: "unassigned",
        members: [],
        roles: [unassigned],
        channels: [],
        autocompleteChoices: [],
        availableOptions: []
    )

    #expect(suggestions.map(\.title) == ["@Unassigned role"])
    let suggestion = try #require(suggestions.first)
    guard case let .value(argument, displayText) = suggestion.action else {
        Issue.record("Expected a role value suggestion")
        return
    }
    #expect(argument == .role(unassigned.id))
    #expect(displayText == "@Unassigned role")
    guard case let .role(colorHex, iconURL, unicodeEmoji) = suggestion.leadingVisual else {
        Issue.record("Expected a role-colored suggestion visual")
        return
    }
    #expect(colorHex == 0xB45CFF)
    #expect(iconURL == nil)
    #expect(unicodeEmoji == nil)
}

@MainActor
@Test("completed command arguments collapse atomically and copy like Discord mentions")
func commandArgumentsUseAtomicMentionPresentation() throws {
    let application = ApplicationCommandApplication(id: "100", name: "Utility")
    let text = ApplicationCommandOption(
        id: "200/text", name: "text", type: .string, isRequired: true
    )
    let user = ApplicationCommandOption(
        id: "200/user", name: "user", type: .user, isRequired: true
    )
    let command = composerFixtureCommand(
        id: "200", name: "sayas", application: application,
        options: [text, user]
    )
    let userID = try #require(UserID("901"))
    let model = ApplicationCommandComposerModel()
    model.activate(command)
    model.setValue(.string("testing"), displayText: "testing", for: text)
    model.setValue(.user(userID), displayText: "@exy1", for: user)
    #expect(model.value(for: user) == .user(userID))
    #expect(model.draftText(for: user) == "@exy1")

    let document = ApplicationCommandTextDocument.make(
        command: command,
        options: [text, user],
        values: [text.id: .string("testing"), user.id: .user(userID)],
        drafts: [text.id: "testing", user.id: "@exy1"],
        roles: [],
        focusedOptionID: nil
    )

    #expect(document.attributedText.string == "/sayas   text \u{FFFC}   user \u{FFFC}")
    #expect(document.segments.allSatisfy { segment in
        ApplicationCommandEditorTextMap.isAtomicValue(
            optionID: segment.option.id,
            in: document.attributedText
        )
    })
    #expect(ApplicationCommandClipboardSerializer.string(
        from: document.attributedText,
        range: NSRange(location: 0, length: document.attributedText.length)
    ) == "/sayas text: testing user: @exy1")

    let userSegment = try #require(document.segment(optionID: user.id))
    let userColor = try #require(document.attributedText.attribute(
        .foregroundColor,
        at: userSegment.valueRange.location,
        effectiveRange: nil
    ) as? NSColor)
    #expect(userColor == .controlAccentColor)
    #expect(document.attributedText.attribute(
        .applicationCommandOptionID,
        at: userSegment.valueRange.location,
        effectiveRange: nil
    ) as? String == user.id)

    let textView = ApplicationCommandNSTextView()
    let pasteboard = NSPasteboard(
        name: NSPasteboard.Name(
            "dev.sakuracord.tests.command-copy.\(UUID().uuidString)"
        )
    )
    defer { pasteboard.clearContents() }
    textView.commandPasteboard = pasteboard
    textView.textStorage?.setAttributedString(document.attributedText)
    textView.setSelectedRange(NSRange(location: 0, length: document.attributedText.length))
    textView.copy(nil)
    #expect(
        pasteboard.string(forType: .string)
            == "/sayas text: testing user: @exy1"
    )
}

@Test("live command text mapping keeps field focus through local edits")
@MainActor
func liveCommandTextMappingKeepsEditingFocus() throws {
    let application = ApplicationCommandApplication(id: "100", name: "Utility")
    let option = ApplicationCommandOption(
        id: "200/text", name: "text", type: .string, isRequired: true
    )
    let command = composerFixtureCommand(
        id: "200", name: "say", application: application, options: [option]
    )
    let document = ApplicationCommandTextDocument.make(
        command: command,
        options: [option],
        values: [option.id: .string("test")],
        drafts: [option.id: "test"],
        roles: [],
        focusedOptionID: option.id
    )
    let segment = try #require(document.segment(optionID: option.id))
    let live = NSMutableAttributedString(attributedString: document.attributedText)
    let attributes = live.attributes(
        at: segment.valueRange.location,
        effectiveRange: nil
    )
    live.insert(
        NSAttributedString(string: "!", attributes: attributes),
        at: NSMaxRange(segment.valueRange)
    )
    let caret = NSMaxRange(segment.valueRange) + 1

    #expect(ApplicationCommandEditorTextMap.optionID(atCaret: caret, in: live) == option.id)
    #expect(ApplicationCommandEditorTextMap.editableText(optionID: option.id, in: live) == "test!")
    #expect(ApplicationCommandEditorTextMap.optionID(atCaret: live.length, in: live) == option.id)
    #expect(ApplicationCommandEditorTextMap.fieldPart(
        atCharacter: segment.labelRange.location,
        in: live
    ) == "label")
}
