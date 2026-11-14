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

    #expect(model.sections(query: "verify").flatMap(\.commands).map(\.id) == ["200", "201"])
    #expect(model.sections(query: "vys").flatMap(\.commands).map(\.id) == ["202"])
    #expect(model.sections(query: "utility").flatMap(\.commands).map(\.id) == ["202"])
    #expect(model.sections(query: "verify").flatMap(\.commands).map(\.id) == ["200", "201"])
}

@MainActor
@Test("command index invalidation restarts a preload before the picker is opened")
func commandIndexInvalidationDuringPreload() {
    let guild = ApplicationCommandIndexTarget.guild(GuildID(rawValue: 600))
    for target in [guild, .user] {
        let model = ApplicationCommandComposerModel()
        model.beginLoading(targets: [guild, .user])
        #expect(!model.isPickerPresented)
        #expect(!model.invalidated(.channel(ChannelID(rawValue: 700))))
        // AppModel uses this result to cancel the old aggregate load and start
        // a replacement, rather than accepting the other index by itself.
        #expect(model.invalidated(target))
        #expect(!model.hasLoadedCatalogs)

        model.replaceCatalogs([
            ApplicationCommandCatalog(target: guild, applications: [], commands: []),
            ApplicationCommandCatalog(target: .user, applications: [], commands: [])
        ])
        #expect(model.hasLoadedCatalogs)
        #expect(!model.isLoading)
        // An idle, closed picker still refreshes lazily on its next opening.
        #expect(!model.invalidated(target))
        #expect(!model.hasLoadedCatalogs)
    }
}

@MainActor
@Test("remote index updates preserve built-in command drafts")
func commandIndexInvalidationPreservesBuiltInDraft() throws {
    let model = ApplicationCommandComposerModel()
    model.beginLoading(targets: [.user])
    model.replaceCatalogs([ApplicationCommandCatalog(target: .user, applications: [], commands: [])])
    let command = try #require(DiscordBuiltInCommands.all.first { $0.name == "nick" })
    model.activate(command)
    let option = try #require(command.options.first)
    model.addOption(option)
    model.setText("Unsaved nickname", for: .field(option.id))
    let before = try #require(model.draft)
    #expect(!model.invalidated(.user))
    #expect(model.draft == before)

    // A remote command from that index still follows the invalidation path.
    model.activate(researchCommand())
    #expect(model.invalidated(.user))
    #expect(model.draft == nil)
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

    // Reusing a prepared catalog across conversations must still apply the
    // destination's permissions, and must not retain an old command definition.
    let model = ApplicationCommandComposerModel()
    command.integrationTypes = [0]
    command.permissions = [.init(id: channelID.description, type: 3, allows: false)]
    let otherChannel = Channel(id: ChannelID(rawValue: 701), guildID: guildID, name: "other")
    func load(in destination: Channel) {
        model.resetForChannelChange()
        model.replaceCatalogs([
            ApplicationCommandCatalog(target: .guild(guildID), applications: [application], commands: [command])
        ], channel: destination, currentUserID: userID)
    }
    load(in: otherChannel)
    #expect(model.sections(query: "verify").flatMap(\.commands).map(\.id) == [command.id])
    load(in: channel)
    #expect(model.sections(query: "verify").flatMap(\.commands).isEmpty)
    load(in: otherChannel)
    #expect(model.sections(query: "verify").flatMap(\.commands).map(\.id) == [command.id])
    command.name = "inspect"
    load(in: otherChannel)
    #expect(model.sections(query: "verify").flatMap(\.commands).isEmpty)
    #expect(model.sections(query: "inspect").flatMap(\.commands).map(\.id) == [command.id])
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

    #expect(ApplicationCommandAvailability.contextIndexTarget(for: botDM) == .channel(botDM.id))
    #expect(ApplicationCommandAvailability.contextIndexTarget(for: privateDM) == nil)
    #expect(ApplicationCommandAvailability.contextIndexTarget(for: groupDM) == nil)
    let guild = Channel(id: ChannelID(rawValue: 703), guildID: GuildID(rawValue: 600), name: "general")
    #expect(ApplicationCommandAvailability.contextIndexTarget(for: guild) == .guild(GuildID(rawValue: 600)))

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

    command.contexts = []
    #expect(!ApplicationCommandAvailability.isAvailable(
        command, channel: privateDM, currentUserID: nil, memberRoleIDs: []
    ))
    #expect(!ApplicationCommandAvailability.isAvailable(
        command, channel: botDM, currentUserID: nil, memberRoleIDs: []
    ))

    // User-installed indexes supply bot_id without an expanded bot user.
    command.application.bot = nil
    command.application.botID = bot.id
    command.contexts = [1]
    #expect(ApplicationCommandAvailability.isAvailable(
        command, channel: botDM, currentUserID: nil, memberRoleIDs: [], indexTarget: .user
    ))
    #expect(!ApplicationCommandAvailability.isAvailable(
        command, channel: privateDM, currentUserID: nil, memberRoleIDs: [], indexTarget: .user
    ))
}

private let composerApplication = ApplicationCommandApplication(id: "100", name: "Utility")

/// /research text:(required, 2-12) count:(optional integer -3...7) who:(optional user) note:(optional)
private func researchCommand() -> ApplicationCommand {
    composerFixtureCommand(
        id: "200", name: "research", application: composerApplication,
        options: [
            ApplicationCommandOption(
                id: "200/text", name: "text", type: .string, isRequired: true,
                minimumLength: 2, maximumLength: 12
            ),
            ApplicationCommandOption(
                id: "200/count", name: "count", type: .integer, minimumValue: -3, maximumValue: 7
            ),
            ApplicationCommandOption(id: "200/who", name: "who", type: .user),
            ApplicationCommandOption(id: "200/note", name: "note", type: .string)
        ]
    )
}

@MainActor
@Test("optional fields insert at the typed gap while values keep definition order")
func commandDraftFieldOrder() throws {
    var draft = ApplicationCommandDraft(command: researchCommand())
    #expect(draft.fields.map(\.option.name) == ["text"])
    #expect(draft.focus == .field("200/text"))

    draft.setText("hello", for: "200/text")
    draft.focus = draft.endGap
    let added = draft.addOption(try #require(draft.availableOptions.last))
    #expect(added)
    draft.setText("later", for: "200/note")
    // A name typed in the gap before `note` lands there, as in Discord.
    draft.focus = .gap(1)
    draft.gapText = "count:"
    let accepted = draft.acceptTypedOptionName()
    #expect(accepted)
    draft.setText("5", for: "200/count")

    #expect(draft.fields.map(\.option.name) == ["text", "count", "note"])
    #expect(draft.focus == .field("200/count"))
    #expect(draft.optionValues().map(\.name) == ["text", "count", "note"])
    #expect(draft.optionValues().map(\.argument) == [.string("hello"), .integer(5), .string("later")])
    #expect(draft.plainText == "/research text:hello count:5 note:later")
}

@MainActor
@Test("backspace from a gap follows Discord's chip semantics")
func commandDraftBackspaceSemantics() throws {
    var draft = ApplicationCommandDraft(command: researchCommand())
    draft.setText("ab", for: "200/text")
    let who = try #require(draft.availableOptions.first { $0.name == "who" })
    draft.focus = draft.endGap
    draft.addOption(who)
    draft.resolve("200/who", to: .user(UserID(rawValue: 123_456_789_012_345_678)), display: "@person")
    let note = try #require(draft.availableOptions.first { $0.name == "note" })
    draft.focus = draft.endGap
    draft.addOption(note)

    // An empty optional chip is removed and the caret stays in its gap.
    let removedEmpty = draft.deleteBackward(intoFieldBefore: 3)
    #expect(removedEmpty == .gap(2))
    #expect(draft.fields.map(\.option.name) == ["text", "who"])
    // A chosen entity is deleted as one token; the chip stays focused.
    let clearedToken = draft.deleteBackward(intoFieldBefore: 2)
    #expect(clearedToken == .field("200/who"))
    #expect(draft.field("200/who")?.text == "")
    #expect(draft.field("200/who")?.resolved == nil)
    // Text loses only its last character.
    let trimmed = draft.deleteBackward(intoFieldBefore: 1)
    #expect(trimmed == .field("200/text"))
    #expect(draft.field("200/text")?.text == "a")
    // Nothing precedes the first chip; that Backspace converts to plain text.
    let beforeFirst = draft.deleteBackward(intoFieldBefore: 0)
    #expect(beforeFirst == nil)
    let document = ApplicationCommandEditorDocument(draft: draft)
    #expect(document.edit(replacing: NSRange(location: document.command.length - 1, length: 1), with: "", draft: draft)
        == .cancel(restoringText: "/researc text:a who:"))
}

@MainActor
@Test("invalid fields block submission with Discord-style feedback and focus")
func commandDraftValidation() throws {
    let model = ApplicationCommandComposerModel()
    model.activate(researchCommand())
    #expect(!model.canSubmit)
    #expect(!model.prepareSubmission())
    #expect(model.fieldIssue == ApplicationCommandFieldIssue(fieldID: "200/text", message: "This option is required."))

    model.setText("a", for: .field("200/text"))
    #expect(!model.prepareSubmission())
    #expect(model.fieldIssue?.message == "Enter between 2 and 12 characters.")
    // Discord counts Unicode scalars, so a combined emoji can exceed the limit.
    model.setText("🌸🌸🌸🌸🌸🌸🌸🌸🌸🌸🌸🌸🌸", for: .field("200/text"))
    #expect(!model.prepareSubmission())
    model.setText("ok", for: .field("200/text"))
    #expect(model.fieldIssue == nil)

    model.setText("", for: .gap(1))
    model.setText("count:", for: .gap(1))
    #expect(model.draft?.focus == .field("200/count"))
    for (text, message) in [
        ("x", "Enter a whole number."),
        ("8", "Enter a number between -3 and 7."),
        ("99999999999999999", "This number is too large."),
        (String(Int64.min), "This number is too large.")
    ] {
        model.setText(text, for: .field("200/count"))
        #expect(!model.prepareSubmission())
        #expect(model.fieldIssue == ApplicationCommandFieldIssue(fieldID: "200/count", message: message))
        #expect(model.draft?.focus == .field("200/count"))
    }
    model.setText("-3", for: .field("200/count"))
    #expect(model.prepareSubmission())
    let invocation = try #require(model.invocation(channelID: ChannelID(rawValue: 300), guildID: nil))
    #expect(invocation.values.map(\.argument) == [.string("ok"), .integer(-3)])
    model.removeField("200/text")
    #expect(model.draft?.field("200/text") == nil)
    #expect(model.draft?.availableOptions.contains(where: { $0.id == "200/text" }) == true)
    #expect(!model.canSubmit)
    #expect(!model.prepareSubmission())
    #expect(model.draft?.focusedField?.id == "200/text")
    #expect(model.fieldIssue?.message == "This option is required.")
}

@MainActor
@Test("autocomplete results are scoped by nonce to the field and query that asked")
func commandAutocompleteNonceScoping() throws {
    let model = ApplicationCommandComposerModel()
    let query = ApplicationCommandOption(
        id: "300/query", name: "query", type: .string, isRequired: true, usesAutocomplete: true
    )
    model.activate(composerFixtureCommand(id: "300", name: "find", application: composerApplication, options: [query]))
    let channelID = ChannelID(rawValue: 400)
    let choice = { (name: String) in ApplicationCommandChoice(name: name, value: .string(name)) }

    let first = try #require(model.autocompleteRequest(channelID: channelID, guildID: nil))
    #expect(first.query == "")
    #expect(model.autocompleteRequest(channelID: channelID, guildID: nil) == nil)
    model.setText("al", for: .field("300/query"))
    let second = try #require(model.autocompleteRequest(channelID: channelID, guildID: nil))
    #expect(second.query == "al")
    #expect(model.autocompleteStatus.isLoading)

    // A superseded answer is cached but never replaces the current list.
    model.receiveAutocomplete(.init(nonce: first.nonce, choices: [choice("stale")]))
    #expect(model.autocompleteStatus.isLoading)
    // A failure for an unrelated nonce is not an autocomplete failure.
    #expect(!model.failAutocomplete(nonce: "other", failure: InteractionFailure(reasonCode: 2)))
    model.receiveAutocomplete(.init(nonce: second.nonce, choices: [choice("alpha")]))
    #expect(model.autocompleteStatus == .loaded([choice("alpha")]))

    // Returning to the earlier query uses the cached answer without a request.
    model.setText("", for: .field("300/query"))
    #expect(model.autocompleteRequest(channelID: channelID, guildID: nil) == nil)
    #expect(model.autocompleteStatus == .loaded([choice("stale")]))

    model.resolveFocusedField(.string("wire-value"), display: "Displayed choice")
    model.setFocus(.field(query.id))
    let refocused = try #require(model.autocompleteRequest(channelID: channelID, guildID: nil))
    #expect(refocused.query == "Displayed choice")
    #expect(model.draft?.field(query.id)?.resolved == .string("wire-value"))
}

@MainActor
@Test("attachment paste fills the right option and ignores outdated targets")
func attachmentPasteTargetLifecycle() throws {
    let model = ApplicationCommandComposerModel()
    let first = ApplicationCommandOption(id: "200/first", name: "first", type: .attachment, isRequired: true)
    let second = ApplicationCommandOption(id: "200/second", name: "second", type: .attachment, isRequired: true)
    let command = composerFixtureCommand(id: "200", name: "files", application: composerApplication, options: [first, second])
    let oldURL = URL(fileURLWithPath: "/old.txt")
    let newURL = URL(fileURLWithPath: "/new.txt")
    model.activate(command)
    #expect(model.pastedAttachmentOption?.id == first.id)

    let changedFocus = try #require(model.attachmentPasteTarget())
    model.setFocus(.field(second.id))
    #expect(!model.finishAttachmentPaste(oldURL, target: changedFocus))
    #expect(model.attachmentURLs.isEmpty)

    let changedCommand = try #require(model.attachmentPasteTarget())
    model.cancelActiveCommand()
    model.activate(command)
    #expect(!model.finishAttachmentPaste(oldURL, target: changedCommand))

    let current = try #require(model.attachmentPasteTarget())
    #expect(model.finishAttachmentPaste(newURL, target: current))
    #expect(model.draft?.field(first.id)?.resolved == .attachment(newURL))
    // The caret moves on, and the next paste targets the empty option.
    #expect(model.draft?.focus == .gap(1))
    #expect(model.pastedAttachmentOption?.id == second.id)

    var optional = second
    optional.isRequired = false
    model.activate(composerFixtureCommand(id: "201", name: "optional", application: composerApplication, options: [optional]))
    #expect(model.draft?.fields.isEmpty == true)
    let optionalTarget = try #require(model.attachmentPasteTarget())
    #expect(model.finishAttachmentPaste(newURL, target: optionalTarget))
    #expect(model.draft?.field(optional.id)?.resolved == .attachment(newURL))
}

@MainActor
@Test("autocomplete retries failures and isolates new drafts and conversations")
func commandAutocompleteLifecycle() throws {
    let model = ApplicationCommandComposerModel()
    let option = ApplicationCommandOption(id: "300/query", name: "query", type: .string, isRequired: true, usesAutocomplete: true)
    let command = composerFixtureCommand(id: "300", name: "find", application: composerApplication, options: [option])
    let channel = ChannelID(rawValue: 400)
    model.activate(command)
    let first = try #require(model.autocompleteRequest(channelID: channel, guildID: nil))
    #expect(model.failAutocomplete(nonce: first.nonce, failure: InteractionFailure(reasonCode: 2)))
    model.setText("changed", for: .field(option.id))
    _ = model.autocompleteRequest(channelID: channel, guildID: nil)
    model.setText("", for: .field(option.id))
    let retry = try #require(model.autocompleteRequest(channelID: channel, guildID: nil))
    model.receiveAutocomplete(.init(nonce: first.nonce, choices: [.init(name: "obsolete", value: .string("obsolete"))]))
    #expect(model.autocompleteStatus.isLoading)
    #expect(model.isAutocompleteRequestCurrent(retry.nonce))
    model.abandonAutocomplete(nonce: retry.nonce, message: "Cancelled")
    let afterDebounceCancellation = try #require(model.autocompleteRequest(channelID: channel, guildID: nil))
    model.cancelActiveCommand()
    model.activate(command)
    #expect(!model.isAutocompleteRequestCurrent(afterDebounceCancellation.nonce))
    _ = try #require(model.autocompleteRequest(channelID: channel, guildID: nil))
    let differentChannel = try #require(model.autocompleteRequest(channelID: ChannelID(rawValue: 401), guildID: nil))
    #expect(differentChannel.invocation.channelID != channel)
}

@MainActor
@Test("command copying and submission preserve literal Unicode and whitespace values")
func commandLiteralTextPreservation() throws {
    var draft = ApplicationCommandDraft(command: researchCommand())
    let value = " 🌸  e\u{301} "
    draft.setText(value, for: "200/text")
    let document = ApplicationCommandEditorDocument(draft: draft)
    let span = try #require(document.span("200/text"))
    #expect(document.plainText(in: span.value) == value)
    #expect(document.plainText(in: NSRange(location: 0, length: document.length)) == "/research text:" + value + " ")
    #expect(draft.optionValues().first?.argument == .string(value))
}

@MainActor
@Test("returned modals settle their opener and late successes cannot close another form")
func commandInteractionModalOrdering() throws {
    let model = AppModel(launchMode: .offlineTesting)
    let channel = ChannelID(rawValue: 400)
    model.trackInteraction(.init(kind: .command(channelID: channel, commandName: "find", application: composerApplication)), nonce: "opening")
    #expect(model.interactionDeadlineTasks.isEmpty)
    model.startInteractionDeadline(nonce: "opening")
    #expect(model.interactionDeadlineTasks.count == 1)
    let modal = InteractionModal(interactionID: "modal-one", openingNonce: "opening", application: composerApplication,
        channelID: channel, guildID: nil, customID: "form", title: "Form", nodes: [])
    model.consumeInteraction(.presentModal(modal))
    #expect(model.pendingInteractions["opening"]?.isFinished == true)
    #expect(model.interactionDeadlineTasks.isEmpty)
    let form = try #require(model.interactionModalForm)
    model.consumeInteraction(.failed(nonce: "opening", failure: .init(reasonCode: 2)))
    #expect(model.interactionModalForm === form)
    model.trackInteraction(.init(kind: .modalSubmission(channelID: channel, application: composerApplication, formID: "older-form")), nonce: "older-submit")
    model.consumeInteraction(.succeeded(nonce: "older-submit", interactionID: "old"))
    #expect(model.interactionModalForm === form)
    model.trackInteraction(.init(kind: .modalSubmission(channelID: channel, application: composerApplication, formID: form.id)), nonce: "submit")
    form.beginSubmitting()
    model.consumeInteraction(.succeeded(nonce: "submit", interactionID: "current"))
    #expect(model.interactionModalForm == nil)
    #expect(model.finishPendingInteraction("submit") == nil)
}

@MainActor
@Test("typing implicitly enters only a sole optional non-attachment option")
func commandImplicitOptionEntry() throws {
    let application = ApplicationCommandApplication(id: "100", name: "Fixture")
    let optional = ApplicationCommandOption(id: "value", name: "value", description: "", type: .string)
    for text in ["x", " ", "value:", "🌸 café"] {
        let model = ApplicationCommandComposerModel()
        model.activate(composerFixtureCommand(id: "200", name: "single", application: application, options: [optional]))
        model.setText(text, for: .gap(0))
        #expect(model.draft?.focus == .field(optional.id))
        #expect(model.draft?.field(optional.id)?.text == text)
        #expect(model.draft?.gapTexts == ["", ""])
    }
    for type in [ApplicationCommandOptionType.string, .user, .attachment] {
        for required in [false, true] {
            var option = optional
            option.type = type
            option.isRequired = required
            let model = ApplicationCommandComposerModel()
            model.activate(composerFixtureCommand(id: "201", name: "single", application: application, options: [option]))
            var draft = try #require(model.draft)
            draft.removeField(option.id)
            draft.focus = .gap(0)
            model.applyEditorDraft(draft, caret: nil)
            model.setText("ex", for: .gap(0))
            #expect(model.draft?.fields.isEmpty == (required || type == .attachment))
        }
    }
    var second = optional
    second.id = "other"
    second.name = "other"
    let model = ApplicationCommandComposerModel()
    model.activate(composerFixtureCommand(id: "202", name: "multiple", application: application, options: [optional, second]))
    model.addOption(optional)
    model.setText("filled", for: .field(optional.id))
    model.setText("x", for: .gap(1))
    #expect(model.draft?.fields.map(\.id) == [optional.id])
    #expect(model.draft?.gapText == "x")
}
