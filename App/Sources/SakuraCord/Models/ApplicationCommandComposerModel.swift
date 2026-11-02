import Foundation
import Observation
import SakuraCordModels

struct ApplicationCommandSection: Identifiable, Equatable {
    enum Kind: Hashable {
        case frequentlyUsed
        case application(String)
        /// One ranked list while searching, as Discord shows it.
        case searchResults
    }

    var kind: Kind
    var title: String
    var application: ApplicationCommandApplication?
    var commands: [ApplicationCommand]

    var id: String {
        switch kind {
        case .frequentlyUsed: "frequently-used"
        case let .application(id): "application:\(id)"
        case .searchResults: "search-results"
        }
    }
}

/// Commands SakuraCord handles locally. They appear in every conversation's
/// picker and never reach Discord.
enum SakuraCordBuiltInCommands {
    static let application = ApplicationCommandApplication(
        id: "sakuracord", name: "SakuraCord", description: "Built into SakuraCord"
    )

    static let commands = [
        command("bug", description: "Report a bug in SakuraCord"),
        command("suggest", description: "Suggest a feature for SakuraCord"),
    ]

    static func issueReportKind(for command: ApplicationCommand) -> IssueReportKind? {
        guard command.applicationID == application.id else { return nil }
        return switch command.name {
        case "bug": .bug
        case "suggest": .feature
        default: nil
        }
    }

    /// Only the community bot's reporting slash commands are replaced locally.
    static func replaces(_ command: ApplicationCommand) -> Bool {
        command.applicationID == AppModel.issueReportAuthorization.clientID
            && command.type == .chatInput
            && (command.name == "bug" || command.name == "suggest")
    }

    private static func command(_ name: String, description: String) -> ApplicationCommand {
        ApplicationCommand(
            id: "sakuracord:\(name)", rootCommandID: "sakuracord:\(name)",
            applicationID: application.id, version: "1", name: name,
            description: description, application: application
        )
    }
}

enum ApplicationCommandAutocompleteStatus: Equatable {
    case idle
    /// Previous choices stay visible while the next query loads.
    case loading(previous: [ApplicationCommandChoice])
    case loaded([ApplicationCommandChoice])
    case failed(String)

    var choices: [ApplicationCommandChoice] {
        switch self {
        case let .loading(previous): previous
        case let .loaded(choices): choices
        case .idle, .failed: []
        }
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

/// Feedback shown when a submission is attempted with an invalid field.
struct ApplicationCommandFieldIssue: Equatable {
    var fieldID: String
    var message: String
}

@MainActor
@Observable
final class ApplicationCommandComposerModel {
    private struct AutocompleteKey: Hashable {
        var commandID: String
        var optionID: String
        var query: String
        var channelID: ChannelID
        var guildID: GuildID?
        var siblings: [ApplicationCommandOptionValue]
    }

    // MARK: Catalogue

    /// Every slash command offered here: applications, Discord built-ins and
    /// SakuraCord's own.
    private(set) var commands: [ApplicationCommand] = SakuraCordBuiltInCommands.commands {
        didSet { refreshPickerSections() }
    }

    /// User and message context-menu commands available in this conversation.
    private(set) var contextMenuCommands: [ApplicationCommand] = []
    private(set) var applications = [SakuraCordBuiltInCommands.application]
    /// Discord's catalogues for this conversation, not counting built-ins.
    private(set) var hasLoadedCatalogs = false
    private(set) var isLoading = false
    private(set) var loadError: String?
    private(set) var currentTargets: Set<ApplicationCommandIndexTarget> = []

    // MARK: Picker

    private(set) var isPickerPresented = false
    private(set) var searchText = ""
    /// The highlighted picker row (`section/command`): Frequently Used rows
    /// repeat under their application, as in Discord.
    var selectedRowID: String?
    /// Sections for `searchText`, computed once per query rather than per render.
    private(set) var pickerSections: [ApplicationCommandSection] = []
    private(set) var pickerKeyboardSelectionRevision = 0

    // MARK: Draft

    /// A clicked `</name:id>` mention, waiting for the composer to start it.
    var mentionedCommand: CommandMention?

    struct CommandMention: Equatable {
        let id: String
        let name: String
    }

    /// The offered command a mention names: its root ID and full name.
    func command(mentioned mention: CommandMention) -> ApplicationCommand? {
        commands.first { command in
            command.rootCommandID == mention.id
                && ApplicationCommandPickerEngine.untranslatedName(of: command) == mention.name
        }
    }

    private(set) var draft: ApplicationCommandDraft? {
        didSet { attachmentPasteRevision &+= 1 }
    }

    /// A caret the editor should adopt; set when the model, not typing, moved it.
    private(set) var caretRequest: ApplicationCommandEditorCaret?
    private(set) var caretRequestRevision = 0
    private(set) var fieldIssue: ApplicationCommandFieldIssue?
    private(set) var autocompleteStatus: ApplicationCommandAutocompleteStatus = .idle
    /// The highlighted suggestion; nil follows the list's default highlight.
    var suggestionIndex: Int?
    var areSuggestionsDismissed = false

    @ObservationIgnored private var attachmentPasteRevision = 0
    /// Discord-synced command usage.
    @ObservationIgnored let frecencyStore: DiscordFrecencyStore
    var memberResults: [Member] = []
    @ObservationIgnored var loadTask: Task<Void, Never>?
    @ObservationIgnored var autocompleteDebounceNonce: String?
    @ObservationIgnored var autocompleteLastQueryTime: ContinuousClock.Instant?
    @ObservationIgnored var autocompleteTask: Task<Void, Never>?
    @ObservationIgnored var memberSearchTask: Task<Void, Never>?
    @ObservationIgnored var memberSearchQuery: CommandMemberQuery?
    @ObservationIgnored var memberSearchCache: [CommandMemberQuery: [Member]] = [:]
    @ObservationIgnored private(set) var conversationGeneration: UInt64 = 0
    @ObservationIgnored private var pickerSources: [ApplicationCommandPickerSource] = [
        ApplicationCommandPickerSource(
            application: SakuraCordBuiltInCommands.application, commands: SakuraCordBuiltInCommands.commands
        )
    ]
    @ObservationIgnored private var availableBuiltIns: [ApplicationCommand] = []
    /// The guild the picker is scoped to; frecency keys depend on it.
    @ObservationIgnored private var contextGuildID: GuildID?
    /// Discord collates and lower-cases with the client locale.
    @ObservationIgnored var locale = Locale(identifier: Locale.preferredLanguages.first ?? "en-US")
    @ObservationIgnored private var autocompleteCache: [AutocompleteKey: [ApplicationCommandChoice]] = [:]
    @ObservationIgnored private var autocompleteCacheOrder: [AutocompleteKey] = []
    @ObservationIgnored private var autocompleteKeyByNonce: [String: AutocompleteKey] = [:]
    @ObservationIgnored private var currentAutocompleteKey: AutocompleteKey?
    @ObservationIgnored private var currentAutocompleteNonce: String?
    @ObservationIgnored private var autocompleteNonceOrder: [String] = []
    @ObservationIgnored private var failedAutocompleteNonces: Set<String> = []

    var activeCommand: ApplicationCommand? { draft?.command }

    init(frecencyStore: DiscordFrecencyStore = DiscordFrecencyStore()) {
        self.frecencyStore = frecencyStore
        refreshPickerSections()
    }

    // MARK: Catalogue loading

    func configureFrecencyScope(_ scope: String) {
        reusablePickerEngine = nil
        frecencyStore.configure(scope: scope)
        refreshPickerSections()
    }

    /// Discord's synced usage changed (initial load, another client, or a save).
    func applyRemoteFrecency(_ history: DiscordFrecencyHistory) {
        frecencyStore.overwrite(with: history)
        refreshPickerSections()
    }

    func beginLoading(targets: Set<ApplicationCommandIndexTarget>) {
        currentTargets = targets
        isLoading = true
        loadError = nil
    }

    /// Builds the picker the way Discord's index store does: each application
    /// once, user-installed commands before guild-only ones, and the
    /// built-ins Discord offers in this conversation.
    func replaceCatalogs(
        _ catalogs: [ApplicationCommandCatalog],
        channel: Channel? = nil,
        currentUserID: UserID? = nil,
        memberRoleIDs: Set<RoleID> = [],
        builtInContext: DiscordBuiltInCommands.Context? = nil
    ) {
        var applicationOrder: [String] = []
        var applicationsByID: [String: ApplicationCommandApplication] = [:]
        var userCommands: [String: [ApplicationCommand]] = [:]
        var contextCommands: [String: [ApplicationCommand]] = [:]
        var contextByID: [String: ApplicationCommand] = [:]
        for catalog in catalogs {
            for application in catalog.applications where applicationsByID[application.id] == nil {
                applicationsByID[application.id] = application
                applicationOrder.append(application.id)
            }
            for command in catalog.commands
                where channel == nil || ApplicationCommandAvailability.isAvailable(
                    command,
                    channel: channel,
                    currentUserID: currentUserID,
                    memberRoleIDs: memberRoleIDs,
                    indexTarget: catalog.target
                )
            {
                switch command.type {
                case .chatInput:
                    guard !SakuraCordBuiltInCommands.replaces(command) else { continue }
                    if catalog.target == .user {
                        userCommands[command.applicationID, default: []].append(command)
                    } else {
                        contextCommands[command.applicationID, default: []].append(command)
                    }
                case .user, .message:
                    if contextByID[command.id] == nil { contextByID[command.id] = command }
                default:
                    break
                }
            }
        }
        var sources: [ApplicationCommandPickerSource] = []
        for id in applicationOrder {
            guard let application = applicationsByID[id] else { continue }
            let user = userCommands[id] ?? []
            let userIDs = Set(user.map(ApplicationCommandPickerEngine.discordID(of:)))
            let merged = user + (contextCommands[id] ?? []).filter {
                !userIDs.contains(ApplicationCommandPickerEngine.discordID(of: $0))
            }
            sources.append(ApplicationCommandPickerSource(application: application, commands: merged))
        }
        sources.append(ApplicationCommandPickerSource(
            application: SakuraCordBuiltInCommands.application, commands: SakuraCordBuiltInCommands.commands
        ))
        pickerSources = sources
        availableBuiltIns = builtInContext.map(DiscordBuiltInCommands.available(in:)) ?? []
        contextGuildID = channel?.guildID
        applications = sources.map(\.application)
        contextMenuCommands = contextByID.values.sorted(by: stableCommandOrder)
        commands = sources.flatMap(\.commands) + availableBuiltIns
        reusablePickerEngine = cachedPickerEngine
        hasLoadedCatalogs = true
        isLoading = false
        loadError = nil
        // Loading replaces the provisional built-in list; start from the top.
        selectedRowID = pickerRows.first?.id
    }

    func failLoading(_ message: String) {
        isLoading = false
        loadError = message
    }

    /// Catalogs can arrive before the member list and contain only bot_id.
    /// Enrich every presentation from the same global user identity when it
    /// becomes available, without fetching profiles or restarting the catalog.
    func refreshApplicationIdentities(user: (UserID) -> User?) {
        var replacements: [String: ApplicationCommandApplication] = [:]
        for application in applications {
            guard let id = application.botID ?? application.bot?.id ?? UserID(application.id),
                  let bot = user(id), bot != application.bot else { continue }
            var updated = application
            updated.bot = bot
            replacements[application.id] = updated
        }
        guard !replacements.isEmpty else { return }
        func update(_ command: ApplicationCommand) -> ApplicationCommand {
            var command = command
            if let application = replacements[command.applicationID] { command.application = application }
            return command
        }
        applications = applications.map { replacements[$0.id] ?? $0 }
        pickerSources = pickerSources.map {
            ApplicationCommandPickerSource(application: replacements[$0.application.id] ?? $0.application,
                commands: $0.commands.map(update))
        }
        contextMenuCommands = contextMenuCommands.map(update)
        if let command = draft?.command, replacements[command.applicationID] != nil { draft?.command = update(command) }
        reusablePickerEngine = nil
        // Publish once, after all catalog state is ready for commands.didSet.
        commands = commands.map(update)
    }

    func contextMenuCommands(of type: ApplicationCommandType) -> [ApplicationCommand] {
        contextMenuCommands.filter { $0.type == type }
    }

    func contextMenuSections(
        of type: ApplicationCommandType
    ) -> (frequent: [ApplicationCommand], applications: [(ApplicationCommandApplication, [ApplicationCommand])]) {
        let browse = contextMenuEngine(of: type).browse()
        return (browse.frequentlyUsed, browse.sections.map { ($0.application, $0.commands) })
    }

    func searchContextMenuCommands(of type: ApplicationCommandType, query: String) -> [ApplicationCommand] {
        contextMenuEngine(of: type).search(query, mode: .contextMenu)
    }

    private func contextMenuEngine(of type: ApplicationCommandType) -> ApplicationCommandPickerEngine {
        let grouped = Dictionary(grouping: contextMenuCommands(of: type), by: \.application.id)
        let sources = grouped.values.compactMap { commands -> ApplicationCommandPickerSource? in
            guard let application = commands.first?.application else { return nil }
            return ApplicationCommandPickerSource(application: application, commands: commands)
        }
        return ApplicationCommandPickerEngine(
            sources: sources, builtIns: [], locale: locale,
            frecencyScore: { [weak self] in self?.frecencyScore(for: $0) ?? 0 },
            frequentCommandIDs: ApplicationCommandPickerEngine.scopedCommandIDs(frecencyStore.frequently, guildID: contextGuildID)
        )
    }

    func invalidated(_ target: ApplicationCommandIndexTarget) -> Bool {
        guard currentTargets.contains(target) else { return false }
        let wasActive = activeCommand.map { command in
            guard !DiscordBuiltInCommands.isBuiltIn(command),
                  command.applicationID != SakuraCordBuiltInCommands.application.id
            else { return false }
            return switch target {
            case let .guild(guildID): command.guildID == guildID
            case .channel, .user: command.guildID == nil
            case let .application(applicationID): command.applicationID == applicationID
            }
        } ?? false
        if wasActive { cancelActiveCommand() }
        clearCatalogs()
        loadError = nil
        // Invalidation also cancels the provider's in-flight index fetch.
        // Restart a preload even while the picker is closed, or its surviving
        // catalog could be installed as though both indexes had loaded.
        return isLoading || isPickerPresented || wasActive
    }

    // MARK: Picker

    func presentPicker(query: String = "") {
        guard draft == nil else { return }
        isPickerPresented = true
        updatePickerQuery(query)
    }

    func updatePickerQuery(_ query: String) {
        if searchText != query || pickerNeedsRefresh {
            searchText = query
            refreshPickerSections(invalidateBrowse: false)
        }
        let rows = pickerRows
        if selectedRowID == nil || !rows.contains(where: { $0.id == selectedRowID }) {
            selectedRowID = rows.first?.id
        }
    }

    func dismissPicker() {
        isPickerPresented = false
        if !searchText.isEmpty {
            searchText = ""
            pickerNeedsRefresh = true
        }
        selectedRowID = nil
    }

    struct PickerRow: Identifiable {
        var id: String
        var command: ApplicationCommand
    }

    static func pickerRowID(section: ApplicationCommandSection, command: ApplicationCommand) -> String {
        "\(section.id)/\(command.id)"
    }

    /// Picker rows in keyboard order, including Frequently Used repeats.
    private(set) var pickerRows: [PickerRow] = []
    private(set) var pickerDocumentRows: [ApplicationCommandDocumentRow] = []
    private(set) var pickerDocumentRevision = 0
    private(set) var pickerDocumentHeight: CGFloat = 0
    @ObservationIgnored private var pickerIndicesByID: [String: Int] = [:]
    @ObservationIgnored private var cachedPickerEngine: ApplicationCommandPickerEngine?
    @ObservationIgnored private var pickerNeedsRefresh = false
    private struct PickerSnapshot {
        let sections: [ApplicationCommandSection]
        let rows: [PickerRow]
        let documentRows: [ApplicationCommandDocumentRow]
        let indices: [String: Int]
        let height: CGFloat
    }
    @ObservationIgnored private var browseSnapshot: PickerSnapshot?

    func movePickerSelection(by delta: Int) {
        let rows = pickerRows
        guard !rows.isEmpty else {
            selectedRowID = nil
            return
        }
        let current = selectedRowID.flatMap { id in pickerIndicesByID[id] } ?? 0
        selectedRowID = rows[(current + delta + rows.count) % rows.count].id
        pickerKeyboardSelectionRevision &+= 1
    }

    var selectedPickerCommand: ApplicationCommand? {
        selectedRowID.flatMap { id in pickerIndicesByID[id].map { pickerRows[$0].command } }
    }

    /// A command whose full name was typed followed by a space. Discord only
    /// activates it when no other command shares or extends that name.
    func exactCommand(named name: String) -> ApplicationCommand? {
        let text = name.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let matches = commands.filter { $0.displayName == text || $0.displayName.hasPrefix(text + " ") }
        return matches.count == 1 && matches[0].displayName == text ? matches[0] : nil
    }

    // MARK: Draft lifecycle

    func activate(_ command: ApplicationCommand) {
        AppPerformanceSignposts.measureSync("CommandActivation") { activateDraft(command) }
    }

    private func activateDraft(_ command: ApplicationCommand) {
        let newDraft = ApplicationCommandDraft(command: command)
        draft = newDraft
        fieldIssue = nil
        resetAutocomplete()
        requestCaret(ApplicationCommandEditorDocument(draft: newDraft).caret(endOf: newDraft.focus))
        dismissPicker()
        resetSuggestions()
    }

    func cancelActiveCommand() {
        draft = nil
        fieldIssue = nil
        caretRequest = nil
        resetAutocomplete()
        resetSuggestions()
    }

    func resetForChannelChange() {
        conversationGeneration &+= 1
        mentionedCommand = nil
        loadTask?.cancel()
        loadTask = nil
        autocompleteTask?.cancel()
        autocompleteTask = nil
        autocompleteDebounceNonce = nil
        autocompleteLastQueryTime = nil
        memberSearchTask?.cancel()
        memberSearchTask = nil
        memberSearchQuery = nil
        memberResults = []
        dismissPicker()
        cancelActiveCommand()
        clearCatalogs()
        currentTargets = []
        isLoading = false
        loadError = nil
    }

    private func clearCatalogs() {
        pickerSources = [ApplicationCommandPickerSource(
            application: SakuraCordBuiltInCommands.application, commands: SakuraCordBuiltInCommands.commands
        )]
        availableBuiltIns = []
        contextGuildID = nil
        commands = SakuraCordBuiltInCommands.commands
        contextMenuCommands = []
        applications = [SakuraCordBuiltInCommands.application]
        hasLoadedCatalogs = false
    }

    // MARK: Editing

    /// Applies a draft produced by the editor for a structural edit.
    func applyEditorDraft(_ updated: ApplicationCommandDraft, caret: ApplicationCommandEditorCaret?) {
        guard draft?.command.id == updated.command.id else { return }
        let focusChanged = draft?.focus != updated.focus
        draft = updated
        if let caret { requestCaret(caret) }
        afterEdit(focusChanged: focusChanged)
    }

    /// Native typing inside one value or gap.
    func setText(_ text: String, for focus: ApplicationCommandDraftFocus) {
        guard var updated = draft else { return }
        var targetFocus = focus
        // An empty first chip leaves a separator that Backspace can remove.
        // It belongs to the command, not to the next implicitly entered value.
        let hasRemovedFieldSeparator = updated.fields.isEmpty && updated.gapText == " "
        switch focus {
        case .command:
            return
        case let .field(id):
            guard updated.field(id)?.text != text else { return }
            updated.setText(text, for: id)
        case .gap:
            let focusChanged = updated.focus != focus
            updated.focus = focus
            guard focusChanged || updated.gapText != text else { return }
            updated.gapText = text
            if focus == .gap(0), text.isEmpty { targetFocus = .command }
        }
        let focusChanged = draft?.focus != targetFocus
        updated.focus = targetFocus
        draft = updated
        if case .gap = targetFocus, var accepted = draft, accepted.acceptImplicitOptionValue() {
            if hasRemovedFieldSeparator, text.hasPrefix(" "), let field = accepted.focusedField {
                accepted.setText(String(text.dropFirst()), for: field.id)
            }
            draft = accepted
            requestCaret(ApplicationCommandEditorDocument(draft: accepted).caret(endOf: accepted.focus))
            afterEdit(focusChanged: true)
            return
        }
        if case .gap = targetFocus, var accepted = draft, accepted.acceptTypedOptionName() {
            draft = accepted
            requestCaret(ApplicationCommandEditorDocument(draft: accepted).caret(endOf: accepted.focus))
            afterEdit(focusChanged: true)
            return
        }
        afterEdit(focusChanged: focusChanged)
    }

    /// The caret moved without changing text.
    func setFocus(_ focus: ApplicationCommandDraftFocus) {
        guard var updated = draft, updated.focus != focus else { return }
        updated.focus = focus
        draft = updated
        afterEdit(focusChanged: true)
    }

    func moveFocus(by delta: Int) {
        guard var updated = draft else { return }
        updated.moveFocus(by: delta)
        guard updated.focus != draft?.focus else { return }
        draft = updated
        requestCaret(ApplicationCommandEditorDocument(draft: updated).selection(for: updated.focus))
        afterEdit(focusChanged: true)
    }

    /// Tab without suggestions advances, except an unrecognized fixed choice
    /// must remain selected for correction (other validation waits for submission).
    func advanceField() {
        if let field = draft?.focusedField, !field.option.choices.isEmpty,
           !field.isEmpty, draft?.argument(for: field) == nil {
            _ = prepareSubmission()
        } else {
            moveFocus(by: 1)
        }
    }

    func focusField(_ id: String) {
        guard var updated = draft, updated.field(id) != nil else { return }
        updated.focus = .field(id)
        draft = updated
        requestCaret(ApplicationCommandEditorDocument(draft: updated).caret(endOf: .field(id)))
        afterEdit(focusChanged: true)
    }

    /// Fills the focused field with a chosen value; like Discord, the caret
    /// then rests in the gap after that chip.
    func resolveFocusedField(_ value: ApplicationCommandArgument, display: String) {
        guard var updated = draft, case let .field(id) = updated.focus else { return }
        updated.resolve(id, to: value, display: display)
        updated.focus = updated.gap(after: id)
        draft = updated
        requestCaret(ApplicationCommandEditorDocument(draft: updated).caret(endOf: updated.focus))
        afterEdit(focusChanged: true)
    }

    func addOption(_ option: ApplicationCommandOption) {
        guard var updated = draft, updated.addOption(option) else { return }
        draft = updated
        requestCaret(ApplicationCommandEditorDocument(draft: updated).caret(endOf: updated.focus))
        afterEdit(focusChanged: true)
    }

    func removeField(_ id: String) {
        guard var updated = draft else { return }
        updated.removeField(id)
        draft = updated
        requestCaret(ApplicationCommandEditorDocument(draft: updated).caret(endOf: updated.focus))
        afterEdit(focusChanged: true)
    }

    private func afterEdit(focusChanged: Bool) {
        if let issue = fieldIssue, let draft,
           draft.field(issue.fieldID).map({ draft.validationError(for: $0) == nil }) ?? true
        {
            fieldIssue = nil
        }
        suggestionIndex = nil
        areSuggestionsDismissed = false
        if focusChanged {
            autocompleteStatus = .idle
            currentAutocompleteKey = nil
            currentAutocompleteNonce = nil
        }
    }

    private func requestCaret(_ caret: ApplicationCommandEditorCaret) {
        caretRequest = caret
        caretRequestRevision &+= 1
    }

    func resetSuggestions() {
        suggestionIndex = nil
        areSuggestionsDismissed = false
    }

    // MARK: Attachments

    /// The option a pasted file fills, as in Discord: the focused attachment
    /// option, otherwise the first attachment field without a file.
    var pastedAttachmentOption: ApplicationCommandOption? {
        guard let draft else { return nil }
        if let field = draft.focusedField, field.option.type == .attachment { return field.option }
        return draft.command.options.first { $0.type == .attachment && draft.field($0.id)?.resolved == nil }
    }

    struct AttachmentPasteTarget {
        fileprivate let revision: Int
        fileprivate let option: ApplicationCommandOption
    }

    func attachmentPasteTarget() -> AttachmentPasteTarget? {
        pastedAttachmentOption.map { AttachmentPasteTarget(revision: attachmentPasteRevision, option: $0) }
    }

    @discardableResult
    func finishAttachmentPaste(_ url: URL, target: AttachmentPasteTarget) -> Bool {
        guard target.revision == attachmentPasteRevision, var updated = draft else { return false }
        if updated.field(target.option.id) == nil { updated.addOption(target.option) }
        updated.resolve(target.option.id, to: .attachment(url), display: url.lastPathComponent)
        updated.focus = updated.gap(after: target.option.id)
        draft = updated
        requestCaret(ApplicationCommandEditorDocument(draft: updated).caret(endOf: updated.focus))
        afterEdit(focusChanged: true)
        return true
    }

    var attachmentURLs: [URL] {
        draft?.attachmentURLs ?? []
    }

    // MARK: Submission

    var canSubmit: Bool {
        draft.map { $0.firstInvalidField == nil } ?? false
    }

    /// Validates before sending. On failure the first invalid field gains
    /// focus and shows Discord-style feedback; nothing is sent.
    func prepareSubmission() -> Bool {
        guard let draft else { return false }
        guard let invalid = draft.firstInvalidField else {
            fieldIssue = nil
            return true
        }
        fieldIssue = ApplicationCommandFieldIssue(fieldID: invalid.field.id, message: invalid.message)
        var updated = draft
        if updated.field(invalid.field.id) == nil {
            updated.focus = .gap(0)
            updated.addOption(invalid.field.option, preservingGapText: true)
        }
        updated.focus = .field(invalid.field.id)
        self.draft = updated
        afterEdit(focusChanged: draft.focus != updated.focus)
        requestCaret(ApplicationCommandEditorDocument(draft: updated).selection(for: updated.focus))
        return false
    }

    func invocation(channelID: ChannelID, guildID: GuildID?) -> ApplicationCommandInvocation? {
        guard let draft else { return nil }
        return ApplicationCommandInvocation(
            command: draft.command, channelID: channelID, guildID: guildID,
            values: draft.optionValues()
        )
    }

    /// Discord records every executed command; SakuraCord's own commands
    /// never enter the synced history.
    func recordUse(of command: ApplicationCommand, guildID: GuildID?) {
        guard command.applicationID != SakuraCordBuiltInCommands.application.id else { return }
        frecencyStore.recordUse(ApplicationCommandPickerEngine.frecencyKey(of: command, guildID: guildID))
        refreshFrecency()
    }

    func refreshFrecency() {
        browseSnapshot = nil
        cachedPickerEngine = nil
        pickerNeedsRefresh = true
        if isPickerPresented { refreshPickerSections() }
    }

    // MARK: Autocomplete

    /// The request the focused field needs, or nil when choices are cached,
    /// already pending, or the field does not use remote autocomplete.
    func autocompleteRequest(channelID: ChannelID, guildID: GuildID?) -> ApplicationCommandAutocompleteRequest? {
        guard let draft, let field = draft.focusedField,
              field.option.usesAutocomplete, field.option.type.supportsAutocomplete
        else {
            currentAutocompleteKey = nil
            currentAutocompleteNonce = nil
            if autocompleteStatus != .idle { autocompleteStatus = .idle }
            return nil
        }
        let siblings = draft.siblingValues(excluding: field.id)
        let key = AutocompleteKey(
            commandID: draft.command.id, optionID: field.id, query: field.text,
            channelID: channelID, guildID: guildID, siblings: siblings
        )
        guard key != currentAutocompleteKey else { return nil }
        currentAutocompleteKey = key
        currentAutocompleteNonce = nil
        if let cached = autocompleteCache[key] {
            autocompleteStatus = .loaded(cached)
            return nil
        }
        let previous = autocompleteStatus.choices
        if let nonce = autocompleteNonceOrder.last(where: {
            autocompleteKeyByNonce[$0] == key && !failedAutocompleteNonces.contains($0)
        }) {
            currentAutocompleteNonce = nonce
            autocompleteStatus = .loading(previous: previous)
            return nil
        }
        autocompleteStatus = .loading(previous: previous)
        let request = ApplicationCommandAutocompleteRequest(
            invocation: ApplicationCommandInvocation(
                command: draft.command, channelID: channelID, guildID: guildID, values: siblings
            ),
            focusedOptionID: field.id,
            query: field.text
        )
        // A retry supersedes failed requests for the same query, while other
        // queries can still populate this draft's bounded cache.
        for nonce in autocompleteNonceOrder where autocompleteKeyByNonce[nonce] == key {
            forgetAutocomplete(nonce)
        }
        autocompleteKeyByNonce[request.nonce] = key
        autocompleteNonceOrder.append(request.nonce)
        currentAutocompleteNonce = request.nonce
        while autocompleteNonceOrder.count > 64 {
            forgetAutocomplete(autocompleteNonceOrder[0])
        }
        return request
    }

    /// Choices are correlated by nonce. A late answer still shows if the person
    /// is waiting on the same field and query; an obsolete one is only cached.
    func receiveAutocomplete(_ result: ApplicationCommandAutocompleteResult) {
        guard let key = autocompleteKeyByNonce[result.nonce] else { return }
        forgetAutocomplete(result.nonce)
        cacheAutocomplete(result.choices, for: key)
        guard key == currentAutocompleteKey, result.nonce == currentAutocompleteNonce else { return }
        autocompleteStatus = .loaded(Array(result.choices.prefix(25)))
        suggestionIndex = nil
    }

    /// Returns true when the nonce belonged to an autocomplete request.
    @discardableResult
    func failAutocomplete(nonce: String, failure: InteractionFailure) -> Bool {
        guard let key = autocompleteKeyByNonce[nonce] else { return false }
        failedAutocompleteNonces.insert(nonce)
        if key == currentAutocompleteKey, nonce == currentAutocompleteNonce, autocompleteStatus.isLoading {
            autocompleteStatus = .failed("Loading options failed")
        }
        return true
    }

    /// A transport error before Discord accepted the request.
    func abandonAutocomplete(nonce: String, message: String) {
        guard let key = autocompleteKeyByNonce[nonce] else { return }
        forgetAutocomplete(nonce)
        if key == currentAutocompleteKey, nonce == currentAutocompleteNonce {
            autocompleteStatus = .failed(message)
            currentAutocompleteKey = nil
            currentAutocompleteNonce = nil
        }
    }

    func isAutocompleteRequestCurrent(_ nonce: String) -> Bool {
        guard let key = autocompleteKeyByNonce[nonce] else { return false }
        return nonce == currentAutocompleteNonce && key == currentAutocompleteKey
    }

    private func forgetAutocomplete(_ nonce: String) {
        autocompleteKeyByNonce[nonce] = nil
        autocompleteNonceOrder.removeAll { $0 == nonce }
        failedAutocompleteNonces.remove(nonce)
    }

    private func cacheAutocomplete(_ choices: [ApplicationCommandChoice], for key: AutocompleteKey) {
        autocompleteCache[key] = Array(choices.prefix(25))
        autocompleteCacheOrder.removeAll { $0 == key }
        autocompleteCacheOrder.append(key)
        if autocompleteCacheOrder.count > 32 {
            autocompleteCache[autocompleteCacheOrder.removeFirst()] = nil
        }
    }

    private func resetAutocomplete() {
        autocompleteStatus = .idle
        currentAutocompleteKey = nil
        autocompleteCache = [:]
        autocompleteCacheOrder = []
        autocompleteKeyByNonce = [:]
        autocompleteNonceOrder = []
        failedAutocompleteNonces = []
        currentAutocompleteNonce = nil
    }

    // MARK: Ranking

    /// Keep one prepared index across channel changes. Availability is still
    /// recomputed per channel; reuse requires the entire filtered catalog to match.
    @ObservationIgnored private var reusablePickerEngine: ApplicationCommandPickerEngine?

    private var pickerEngine: ApplicationCommandPickerEngine {
        if let cachedPickerEngine { return cachedPickerEngine }
        let guildID = contextGuildID
        let store = frecencyStore
        let frequentIDs = ApplicationCommandPickerEngine.scopedCommandIDs(store.frequently, guildID: guildID)
        if var engine = reusablePickerEngine,
           engine.locale == locale, engine.sources == pickerSources, engine.builtIns == availableBuiltIns {
            engine.frecencyScore = { command in
                store.score(for: ApplicationCommandPickerEngine.frecencyKey(of: command, guildID: guildID))
            }
            engine.frequentCommandIDs = frequentIDs
            cachedPickerEngine = engine
            return engine
        }
        let engine = ApplicationCommandPickerEngine(
            sources: pickerSources,
            builtIns: availableBuiltIns,
            locale: locale,
            frecencyScore: { command in
                store.score(for: ApplicationCommandPickerEngine.frecencyKey(of: command, guildID: guildID))
            },
            frequentCommandIDs: frequentIDs
        )
        cachedPickerEngine = engine
        return engine
    }

    func rankedCommands(query: String) -> [ApplicationCommand] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty || query.contains(" ") else {
            return pickerEngine.browse().sections.flatMap(\.commands)
        }
        return pickerEngine.search(query)
    }

    func sections(query: String) -> [ApplicationCommandSection] {
        let engine = pickerEngine
        if query.isEmpty {
            let browse = engine.browse()
            var result: [ApplicationCommandSection] = []
            if !browse.frequentlyUsed.isEmpty {
                result.append(ApplicationCommandSection(
                    kind: .frequentlyUsed, title: "Frequently Used", application: nil,
                    commands: browse.frequentlyUsed
                ))
            }
            result += browse.sections.map {
                ApplicationCommandSection(
                    kind: .application($0.application.id), title: $0.name,
                    application: $0.application, commands: $0.commands
                )
            }
            return result
        }
        let results = engine.search(query)
        guard !results.isEmpty else { return [] }
        let title = ApplicationCommandPickerEngine.parse(query).text
        return [ApplicationCommandSection(
            kind: .searchResults, title: "Commands matching /\(title)", application: nil, commands: results
        )]
    }

    private func refreshPickerSections(invalidateBrowse: Bool = true) {
        if invalidateBrowse { browseSnapshot = nil; cachedPickerEngine = nil }
        pickerNeedsRefresh = false
        AppPerformanceSignposts.measureSync("CommandPickerQuery") {
            if searchText.isEmpty, let cached = browseSnapshot {
                pickerSections = cached.sections
                pickerRows = cached.rows
                pickerDocumentRows = cached.documentRows
                pickerIndicesByID = cached.indices
                pickerDocumentHeight = cached.height
                pickerDocumentRevision &+= 1
                return
            }
            pickerSections = sections(query: searchText)
            pickerRows = pickerSections.flatMap { section in
                section.commands.map { PickerRow(id: Self.pickerRowID(section: section, command: $0), command: $0) }
            }
            pickerIndicesByID = Dictionary(pickerRows.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
            pickerDocumentRows = pickerSections.flatMap { section in
                [ApplicationCommandDocumentRow(section: section)] + section.commands.map {
                    ApplicationCommandDocumentRow(section: section, command: $0)
                }
            }
            pickerDocumentHeight = pickerDocumentRows.reduce(0) { $0 + $1.height }
            if searchText.isEmpty {
                browseSnapshot = PickerSnapshot(sections: pickerSections, rows: pickerRows,
                    documentRows: pickerDocumentRows, indices: pickerIndicesByID, height: pickerDocumentHeight)
            }
            pickerDocumentRevision &+= 1
        }
    }

    private func frecencyScore(for command: ApplicationCommand) -> Double {
        frecencyStore.score(for: ApplicationCommandPickerEngine.frecencyKey(of: command, guildID: contextGuildID))
    }

    private func stableCommandOrder(_ lhs: ApplicationCommand, _ rhs: ApplicationCommand) -> Bool {
        let nameComparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
        if nameComparison != .orderedSame { return nameComparison == .orderedAscending }
        let appComparison = lhs.application.name.localizedStandardCompare(rhs.application.name)
        if appComparison != .orderedSame { return appComparison == .orderedAscending }
        return lhs.id < rhs.id
    }
}

enum ApplicationCommandAvailability {
    /// Ordinary and group DMs use only the user index. The channel endpoint
    /// exposes the recipient bot's commands and rejects human DMs with 10003.
    static func contextIndexTarget(for channel: Channel) -> ApplicationCommandIndexTarget? {
        if let guildID = channel.guildID { return .guild(guildID) }
        if channel.kind == .directMessage, channel.recipients.contains(where: \.isBot) {
            return .channel(channel.id)
        }
        return nil
    }

    static func isAvailable(
        _ command: ApplicationCommand,
        channel: Channel?,
        currentUserID: UserID?,
        memberRoleIDs: Set<RoleID>,
        indexTarget: ApplicationCommandIndexTarget? = nil
    ) -> Bool {
        guard let channel else { return false }
        if !command.integrationTypes.isEmpty {
            let requiredIntegrationType: Int? =
                switch indexTarget {
                case .guild: 0
                case .user: 1
                case .channel, .application, nil: nil
                }
            if let requiredIntegrationType,
               !command.integrationTypes.contains(requiredIntegrationType)
            {
                return false
            }
        }
        let requiredContext: Int
        if channel.guildID != nil {
            requiredContext = 0
        } else if channel.kind == .directMessage,
                  let applicationBotID = command.application.bot?.id ?? command.application.botID,
                  channel.recipients.contains(where: { $0.id == applicationBotID })
        {
            requiredContext = 1
        } else {
            requiredContext = 2
        }
        if !command.contexts.contains(requiredContext) {
            return false
        }
        guard !command.permissions.isEmpty else { return true }

        let channelID = channel.id.description
        let allChannelsID = channel.guildID.flatMap { snowflakeOffset($0.description, by: -1) }
        if let decision = decision(
            in: command.permissions,
            type: 3,
            identifiers: Set([channelID, allChannelsID].compactMap { $0 })
        ) {
            return decision
        }
        if let currentUserID,
           let decision = decision(
               in: command.permissions,
               type: 2,
               identifiers: [currentUserID.description]
           )
        {
            return decision
        }
        if let decision = roleDecision(
            in: command.permissions,
            roleIDs: Set(memberRoleIDs.map(\.description))
        ) {
            return decision
        }
        if let guildID = channel.guildID,
           let decision = decision(
               in: command.permissions,
               type: 1,
               identifiers: [guildID.description]
           )
        {
            return decision
        }
        return true
    }

    private static func decision(
        in permissions: [ApplicationCommandPermission],
        type: Int,
        identifiers: Set<String>
    ) -> Bool? {
        permissions.first { $0.type == type && identifiers.contains($0.id) }?.allows
    }

    private static func roleDecision(
        in permissions: [ApplicationCommandPermission], roleIDs: Set<String>
    ) -> Bool? {
        let matches = permissions.filter { $0.type == 1 && roleIDs.contains($0.id) }
        guard !matches.isEmpty else { return nil }
        return matches.contains(where: \.allows)
    }

    private static func snowflakeOffset(_ value: String, by offset: Int) -> String? {
        guard let number = UInt64(value) else { return nil }
        if offset < 0 {
            guard number >= UInt64(-offset) else { return nil }
            return String(number - UInt64(-offset))
        }
        return String(number + UInt64(offset))
    }
}
