import Foundation
import Observation
import SakuraCordModels

struct ApplicationCommandSection: Identifiable, Equatable {
    enum Kind: Hashable {
        case frequentlyUsed
        case application(String)
    }

    var kind: Kind
    var title: String
    var application: ApplicationCommandApplication?
    var commands: [ApplicationCommand]

    var id: String {
        switch kind {
        case .frequentlyUsed: "frequently-used"
        case let .application(id): "application:\(id)"
        }
    }
}

enum ApplicationCommandAutocompleteStart: Equatable {
    case request
    case pending
    case cached
}

@MainActor
@Observable
final class ApplicationCommandComposerModel {
    private struct AutocompleteKey: Hashable {
        var commandID: String
        var optionID: String
        var query: String
    }

    private struct PendingInvocation {
        var commandName: String
        var localizedName: String?
        var applicationID: String
    }

    private struct FrecencyRecord: Codable {
        var count: Int
        var lastUsed: Date
    }

    private struct CommandSearchMetadata {
        let path: String
        let application: String
        let description: String
    }

    private struct RankedCommand {
        let command: ApplicationCommand
        let searchScore: Int
        let frecencyScore: Double
    }

    private(set) var commands: [ApplicationCommand] = [] {
        didSet {
            commandSearchIndex = Dictionary(uniqueKeysWithValues: commands.map { command in
                (command.id, CommandSearchMetadata(
                    path: normalize(command.displayName),
                    application: normalize(command.application.name),
                    description: normalize(command.displayDescription)
                ))
            })
        }
    }
    private(set) var applications: [ApplicationCommandApplication] = []
    private(set) var isLoading = false
    private(set) var loadError: String?
    private(set) var activeCommand: ApplicationCommand?
    private(set) var includedOptionIDs: Set<String> = []
    private(set) var displayedOptionIDs: [String] = []
    private(set) var values: [String: ApplicationCommandArgument] = [:]
    private(set) var optionDrafts: [String: String] = [:]
    private(set) var focusedOptionID: String?
    private(set) var autocompleteChoices: [ApplicationCommandChoice] = []
    private(set) var autocompleteNonce: String?
    private(set) var isAutocompleteLoading = false
    private(set) var autocompleteError: String?
    private(set) var executionProgress: ApplicationCommandProgress?
    private(set) var executionState: ApplicationCommandExecutionState?
    private(set) var executionError: String?
    private(set) var currentTargets: Set<ApplicationCommandIndexTarget> = []

    var isPickerPresented = false
    var searchText = ""
    var selectedCommandID: String?
    private(set) var pickerKeyboardSelectionRevision = 0

    @ObservationIgnored private var frecency: [String: FrecencyRecord] = [:]
    @ObservationIgnored private var commandSearchIndex: [String: CommandSearchMetadata] = [:]
    @ObservationIgnored private var frecencyDefaultsKey = "dev.sakuracord.command-frecency.offline"
    @ObservationIgnored private var pendingInvocations: [String: PendingInvocation] = [:]
    @ObservationIgnored private var autocompleteCache: [AutocompleteKey: [ApplicationCommandChoice]] = [:]
    @ObservationIgnored private var autocompleteCacheOrder: [AutocompleteKey] = []
    @ObservationIgnored private var autocompleteKeyByNonce: [String: AutocompleteKey] = [:]
    @ObservationIgnored private var pendingAutocompleteNonceByKey: [AutocompleteKey: String] = [:]
    @ObservationIgnored private var recentAutocompleteNonces: Set<String> = []
    @ObservationIgnored private var recentAutocompleteNonceOrder: [String] = []

    var displayedOptions: [ApplicationCommandOption] {
        guard let activeCommand else { return [] }
        let optionsByID = Dictionary(uniqueKeysWithValues: activeCommand.options.map { ($0.id, $0) })
        return displayedOptionIDs.compactMap { optionsByID[$0] }
    }

    var availableOptionalOptions: [ApplicationCommandOption] {
        guard let activeCommand else { return [] }
        return activeCommand.options.filter { !$0.isRequired && !includedOptionIDs.contains($0.id) }
    }

    var focusedOption: ApplicationCommandOption? {
        guard let focusedOptionID else { return nil }
        return activeCommand?.options.first { $0.id == focusedOptionID }
    }

    var canSubmit: Bool {
        guard let command = activeCommand else { return false }
        return command.options.allSatisfy { validationError(for: $0) == nil }
    }

    func validationError(for option: ApplicationCommandOption) -> String? {
        guard let value = values[option.id] else {
            return option.isRequired ? "\(option.displayName) is required." : nil
        }
        switch (option.type, value) {
        case (.string, let .string(text)):
            return stringValidationError(text, option: option)
        case (.integer, let .integer(number)):
            return integerValidationError(number, option: option)
        case (.number, let .number(number)):
            return numberValidationError(number, option: option)
        case (.attachment, let .attachment(url)):
            if !FileManager.default.fileExists(atPath: url.path) {
                return "The selected file is no longer available."
            }
        case (.boolean, .boolean), (.user, .user), (.channel, .channel), (.role, .role),
             (.mentionable, .mentionable):
            break
        default:
            return "This option has an unsupported value."
        }
        return nil
    }

    private func stringValidationError(
        _ text: String,
        option: ApplicationCommandOption
    ) -> String? {
        if let minimum = option.minimumLength, text.count < minimum {
            return "Use at least \(minimum) characters."
        }
        if let maximum = option.maximumLength, text.count > maximum {
            return "Use at most \(maximum) characters."
        }
        return nil
    }

    private func integerValidationError(
        _ number: Int64,
        option: ApplicationCommandOption
    ) -> String? {
        if number < -9_007_199_254_740_991 || number > 9_007_199_254_740_991 {
            return "This number is outside Discord's safe integer range."
        }
        return numericBoundsValidationError(Double(number), option: option)
    }

    private func numberValidationError(
        _ number: Double,
        option: ApplicationCommandOption
    ) -> String? {
        guard number.isFinite else { return "Enter a finite number." }
        return numericBoundsValidationError(number, option: option)
    }

    private func numericBoundsValidationError(
        _ number: Double,
        option: ApplicationCommandOption
    ) -> String? {
        if let minimum = option.minimumValue, number < minimum {
            return "Enter \(minimum) or greater."
        }
        if let maximum = option.maximumValue, number > maximum {
            return "Enter \(maximum) or less."
        }
        return nil
    }

    func configureFrecencyScope(_ scope: String) {
        let safeScope = scope.replacingOccurrences(
            of: #"[^A-Za-z0-9_.-]"#, with: "-", options: .regularExpression
        )
        frecencyDefaultsKey = "dev.sakuracord.command-frecency.\(safeScope)"
        if let data = UserDefaults.standard.data(forKey: frecencyDefaultsKey),
           let value = try? JSONDecoder().decode([String: FrecencyRecord].self, from: data)
        {
            frecency = value
        } else {
            frecency = [:]
        }
    }

    func beginLoading(targets: Set<ApplicationCommandIndexTarget>) {
        currentTargets = targets
        isLoading = true
        loadError = nil
    }

    func replaceCatalogs(
        _ catalogs: [ApplicationCommandCatalog],
        channel: Channel? = nil,
        currentUserID: UserID? = nil,
        memberRoleIDs: Set<RoleID> = []
    ) {
        var applicationsByID: [String: ApplicationCommandApplication] = [:]
        var commandsByID: [String: ApplicationCommand] = [:]
        for catalog in catalogs {
            for application in catalog.applications where applicationsByID[application.id] == nil {
                applicationsByID[application.id] = application
            }
            for command in catalog.commands where command.type == .chatInput
                && (channel == nil || ApplicationCommandAvailability.isAvailable(
                    command,
                    channel: channel,
                    currentUserID: currentUserID,
                    memberRoleIDs: memberRoleIDs,
                    indexTarget: catalog.target
                ))
            {
                if commandsByID[command.id] == nil {
                    commandsByID[command.id] = command
                }
            }
        }
        applications = applicationsByID.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        commands = commandsByID.values.sorted(by: stableCommandOrder)
        isLoading = false
        loadError = nil
        if selectedCommandID == nil || !commands.contains(where: { $0.id == selectedCommandID }) {
            selectedCommandID = rankedCommands(query: searchText).first?.id
        }
    }

    func failLoading(_ message: String) {
        isLoading = false
        loadError = message
    }

    func invalidated(_ target: ApplicationCommandIndexTarget) -> Bool {
        guard currentTargets.contains(target) else { return false }
        let wasActive = activeCommand.map { command in
            switch target {
            case let .guild(guildID): command.guildID == guildID
            case .channel, .user: command.guildID == nil
            case let .application(applicationID): command.applicationID == applicationID
            }
        } ?? false
        if wasActive {
            executionError = "This command changed in Discord. Choose it again before running it."
            cancelActiveCommand()
        }
        commands = []
        applications = []
        loadError = nil
        return isPickerPresented || wasActive
    }

    func presentPicker(query: String = "") {
        guard activeCommand == nil else { return }
        searchText = query
        isPickerPresented = true
        selectedCommandID = rankedCommands(query: query).first?.id
    }

    func updatePickerQuery(_ query: String) {
        searchText = query
        let ranked = rankedCommands(query: query)
        if selectedCommandID == nil || !ranked.contains(where: { $0.id == selectedCommandID }) {
            selectedCommandID = ranked.first?.id
        }
    }

    func dismissPicker() {
        isPickerPresented = false
        searchText = ""
        selectedCommandID = nil
    }

    func movePickerSelection(by delta: Int) {
        let ordered = pickerCommandOrder(query: searchText)
        guard !ordered.isEmpty else {
            selectedCommandID = nil
            return
        }
        let current = selectedCommandID.flatMap { id in ordered.firstIndex { $0.id == id } } ?? 0
        selectedCommandID = ordered[(current + delta + ordered.count) % ordered.count].id
        pickerKeyboardSelectionRevision &+= 1
    }

    func activateSelectedCommand() -> Bool {
        guard let selectedCommandID,
              let command = commands.first(where: { $0.id == selectedCommandID })
        else { return false }
        activate(command)
        return true
    }

    func activate(_ command: ApplicationCommand) {
        activeCommand = command
        displayedOptionIDs = command.options.filter(\.isRequired).map(\.id)
        includedOptionIDs = Set(displayedOptionIDs)
        values = [:]
        optionDrafts = [:]
        focusedOptionID = command.options.first(where: \.isRequired)?.id
        autocompleteChoices = []
        autocompleteNonce = nil
        autocompleteError = nil
        isAutocompleteLoading = false
        executionProgress = nil
        executionState = nil
        executionError = nil
        resetAutocompleteSession()
        dismissPicker()
    }

    func cancelActiveCommand() {
        activeCommand = nil
        includedOptionIDs = []
        displayedOptionIDs = []
        values = [:]
        optionDrafts = [:]
        focusedOptionID = nil
        autocompleteChoices = []
        autocompleteNonce = nil
        isAutocompleteLoading = false
        autocompleteError = nil
        resetAutocompleteSession()
    }

    func addOptionalOption(_ option: ApplicationCommandOption) {
        guard activeCommand?.options.contains(where: { $0.id == option.id }) == true,
              !option.isRequired
        else { return }
        if includedOptionIDs.insert(option.id).inserted {
            displayedOptionIDs.append(option.id)
        }
        focusedOptionID = option.id
    }

    func removeOptionalOption(_ option: ApplicationCommandOption) {
        guard !option.isRequired else { return }
        includedOptionIDs.remove(option.id)
        displayedOptionIDs.removeAll { $0 == option.id }
        values[option.id] = nil
        optionDrafts[option.id] = nil
        if focusedOptionID == option.id {
            leaveOptionFocus()
        }
    }

    func clearValue(for option: ApplicationCommandOption) {
        guard activeCommand?.options.contains(where: { $0.id == option.id }) == true else { return }
        if option.isRequired {
            values[option.id] = nil
            optionDrafts[option.id] = ""
            focus(option)
        } else {
            removeOptionalOption(option)
        }
    }

    func focus(_ option: ApplicationCommandOption) {
        guard displayedOptions.contains(where: { $0.id == option.id }) else { return }
        focusedOptionID = option.id
        clearAutocompleteState()
    }

    func leaveOptionFocus() {
        focusedOptionID = nil
        clearAutocompleteState()
    }

    private func clearAutocompleteState() {
        discardCurrentAutocomplete()
        autocompleteChoices = []
        autocompleteError = nil
    }

    func setValue(_ value: ApplicationCommandArgument?, for option: ApplicationCommandOption) {
        setValue(value, displayText: nil, for: option)
    }

    func setValue(
        _ value: ApplicationCommandArgument?,
        displayText: String?,
        for option: ApplicationCommandOption
    ) {
        guard activeCommand?.options.contains(where: { $0.id == option.id }) == true else { return }
        if value == nil, !option.isRequired {
            includedOptionIDs.remove(option.id)
            displayedOptionIDs.removeAll { $0 == option.id }
        } else {
            includeForDisplayIfNeeded(option)
        }
        values[option.id] = value
        if let displayText {
            optionDrafts[option.id] = displayText
        } else if let value {
            optionDrafts[option.id] = draftText(for: value, option: option)
        } else if optionDrafts[option.id] == nil {
            optionDrafts[option.id] = ""
        }
    }

    func value(for option: ApplicationCommandOption) -> ApplicationCommandArgument? {
        values[option.id]
    }

    func draftText(for option: ApplicationCommandOption) -> String {
        optionDrafts[option.id] ?? values[option.id].map { draftText(for: $0, option: option) } ?? ""
    }

    func updateDraftText(_ text: String, for option: ApplicationCommandOption) {
        guard activeCommand?.options.contains(where: { $0.id == option.id }) == true else { return }
        includeForDisplayIfNeeded(option)
        optionDrafts[option.id] = text
        if !option.choices.isEmpty {
            values[option.id] = nil
            return
        }
        switch option.type {
        case .string:
            values[option.id] = text.isEmpty && !option.isRequired ? nil : .string(text)
        case .integer:
            values[option.id] = Int64(text).map(ApplicationCommandArgument.integer)
        case .number:
            let normalized = text.replacingOccurrences(
                of: Locale.current.decimalSeparator ?? ".", with: "."
            )
            values[option.id] = Double(normalized).flatMap {
                $0.isFinite ? .number($0) : nil
            }
        case .boolean, .user, .channel, .role, .mentionable, .attachment:
            values[option.id] = nil
        default:
            values[option.id] = nil
        }
    }

    func moveOptionFocus(by delta: Int) {
        let options = displayedOptions
        guard !options.isEmpty else { return }
        guard let focusedOptionID,
              let current = options.firstIndex(where: { $0.id == focusedOptionID })
        else {
            focus(delta < 0 ? options[options.count - 1] : options[0])
            return
        }
        let destination = current + delta
        guard options.indices.contains(destination) else {
            leaveOptionFocus()
            return
        }
        focus(options[destination])
    }

    private func includeForDisplayIfNeeded(_ option: ApplicationCommandOption) {
        if includedOptionIDs.insert(option.id).inserted {
            displayedOptionIDs.append(option.id)
        }
    }

    func invocation(channelID: ChannelID, guildID: GuildID?) -> ApplicationCommandInvocation? {
        guard let activeCommand else { return nil }
        let optionValues = activeCommand.options.compactMap { option -> ApplicationCommandOptionValue? in
            guard let value = values[option.id] else { return nil }
            return ApplicationCommandOptionValue(
                optionID: option.id, name: option.name, type: option.type, argument: value
            )
        }
        return ApplicationCommandInvocation(
            command: activeCommand, channelID: channelID, guildID: guildID, values: optionValues
        )
    }

    func prepareAutocomplete(
        option: ApplicationCommandOption,
        query: String,
        nonce: String
    ) -> ApplicationCommandAutocompleteStart {
        guard let activeCommand,
              activeCommand.options.contains(where: { $0.id == option.id })
        else { return .pending }
        let key = AutocompleteKey(
            commandID: activeCommand.id, optionID: option.id, query: query
        )
        if let choices = autocompleteCache[key] {
            discardCurrentAutocomplete()
            autocompleteChoices = choices
            autocompleteError = nil
            isAutocompleteLoading = false
            return .cached
        }
        if let pendingNonce = pendingAutocompleteNonceByKey[key] {
            autocompleteNonce = pendingNonce
            autocompleteChoices = []
            autocompleteError = nil
            isAutocompleteLoading = true
            return .pending
        }
        discardCurrentAutocomplete()
        autocompleteNonce = nonce
        rememberAutocompleteNonce(nonce)
        autocompleteKeyByNonce[nonce] = key
        pendingAutocompleteNonceByKey[key] = nonce
        autocompleteChoices = []
        autocompleteError = nil
        isAutocompleteLoading = true
        return .request
    }

    func receiveAutocomplete(_ result: ApplicationCommandAutocompleteResult) {
        forgetAutocompleteNonce(result.nonce)
        guard let key = autocompleteKeyByNonce.removeValue(forKey: result.nonce) else { return }
        pendingAutocompleteNonceByKey[key] = nil
        cacheAutocomplete(result.choices, for: key)
        guard result.nonce == autocompleteNonce else { return }
        autocompleteChoices = result.choices
        isAutocompleteLoading = false
        autocompleteError = nil
    }

    func failAutocomplete(nonce: String, message: String) {
        if let key = autocompleteKeyByNonce.removeValue(forKey: nonce) {
            pendingAutocompleteNonceByKey[key] = nil
        }
        guard nonce == autocompleteNonce else { return }
        autocompleteNonce = nil
        isAutocompleteLoading = false
        autocompleteError = message
    }

    private func discardCurrentAutocomplete() {
        guard let nonce = autocompleteNonce else { return }
        if let key = autocompleteKeyByNonce.removeValue(forKey: nonce) {
            pendingAutocompleteNonceByKey[key] = nil
        }
        autocompleteNonce = nil
        isAutocompleteLoading = false
    }

    private func cacheAutocomplete(
        _ choices: [ApplicationCommandChoice],
        for key: AutocompleteKey
    ) {
        autocompleteCache[key] = Array(choices.prefix(25))
        autocompleteCacheOrder.removeAll { $0 == key }
        autocompleteCacheOrder.append(key)
        if autocompleteCacheOrder.count > 32 {
            let evicted = autocompleteCacheOrder.removeFirst()
            autocompleteCache[evicted] = nil
        }
    }

    private func resetAutocompleteSession() {
        autocompleteCache = [:]
        autocompleteCacheOrder = []
        autocompleteKeyByNonce = [:]
        pendingAutocompleteNonceByKey = [:]
    }

    private func rememberAutocompleteNonce(_ nonce: String) {
        guard recentAutocompleteNonces.insert(nonce).inserted else { return }
        recentAutocompleteNonceOrder.append(nonce)
        if recentAutocompleteNonceOrder.count > 64 {
            recentAutocompleteNonces.remove(recentAutocompleteNonceOrder.removeFirst())
        }
    }

    private func forgetAutocompleteNonce(_ nonce: String) {
        recentAutocompleteNonces.remove(nonce)
        recentAutocompleteNonceOrder.removeAll { $0 == nonce }
    }

    func updateExecutionProgress(_ progress: ApplicationCommandProgress) {
        executionProgress = progress
        switch progress {
        case let .submitting(nonce):
            executionState = .queued(nonce: nonce)
            if let activeCommand {
                pendingInvocations[nonce] = PendingInvocation(
                    commandName: activeCommand.displayName,
                    localizedName: activeCommand.localizedName,
                    applicationID: activeCommand.applicationID
                )
            }
        case let .awaitingResponse(nonce): executionState = .queued(nonce: nonce)
        default: break
        }
    }

    func interactionCreated(nonce: String, interactionID: String) {
        guard executionState?.nonce == nonce else { return }
        executionState = .created(nonce: nonce, interactionID: interactionID)
    }

    func interactionSucceeded(nonce: String) {
        guard executionState?.nonce == nonce else { return }
        executionState = .succeeded(nonce: nonce)
        executionError = nil
        if let activeCommand {
            recordUse(of: activeCommand)
        }
        cancelActiveCommand()
        executionProgress = nil
    }

    @discardableResult
    func interactionFailed(nonce: String, message: String) -> Bool {
        if recentAutocompleteNonces.contains(nonce) {
            forgetAutocompleteNonce(nonce)
            if nonce == autocompleteNonce {
                failAutocomplete(nonce: nonce, message: message)
            }
            return true
        }
        guard executionState?.nonce == nonce else { return false }
        pendingInvocations[nonce] = nil
        executionState = .failed(nonce: nonce, message: message)
        executionError = message
        executionProgress = nil
        return true
    }

    func failExecution(_ message: String) {
        executionError = message
        executionProgress = nil
    }

    func resetForChannelChange() {
        dismissPicker()
        cancelActiveCommand()
        executionProgress = nil
        executionState = nil
        executionError = nil
        commands = []
        applications = []
        currentTargets = []
        isLoading = false
        loadError = nil
        pendingInvocations = [:]
    }

    func enrichInteractionResponse(_ message: inout Message, currentUser: User?) {
        guard let nonce = message.nonce,
              let pending = pendingInvocations.removeValue(forKey: nonce)
        else { return }
        var metadata = message.interactionMetadata ?? MessageInteractionMetadata()
        metadata.name = metadata.name ?? pending.commandName
        metadata.localizedName = metadata.localizedName ?? pending.localizedName
        metadata.applicationID = metadata.applicationID ?? pending.applicationID
        metadata.user = metadata.user ?? currentUser
        message.interactionMetadata = metadata
    }

    func rankedCommands(query: String) -> [ApplicationCommand] {
        let normalizedQuery = normalize(query)
        let now = Date.now
        return commands.compactMap { command -> RankedCommand? in
            let metadata = commandSearchIndex[command.id]
            if normalizedQuery.isEmpty {
                return RankedCommand(
                    command: command,
                    searchScore: 0,
                    frecencyScore: frecencyScore(for: command, now: now)
                )
            }
            guard let score = searchScore(
                query: normalizedQuery,
                path: metadata?.path ?? normalize(command.displayName),
                application: metadata?.application ?? normalize(command.application.name),
                description: metadata?.description ?? normalize(command.displayDescription)
            ) else { return nil }
            return RankedCommand(
                command: command,
                searchScore: score,
                frecencyScore: frecencyScore(for: command, now: now)
            )
        }.sorted { lhs, rhs in
            if lhs.searchScore != rhs.searchScore { return lhs.searchScore > rhs.searchScore }
            if lhs.frecencyScore != rhs.frecencyScore {
                return lhs.frecencyScore > rhs.frecencyScore
            }
            let lhsRank = lhs.command.globalPopularityRank ?? .max
            let rhsRank = rhs.command.globalPopularityRank ?? .max
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return stableCommandOrder(lhs.command, rhs.command)
        }.map(\.command)
    }

    func sections(query: String) -> [ApplicationCommandSection] {
        let ranked = rankedCommands(query: query)
        guard !ranked.isEmpty else { return [] }
        var result: [ApplicationCommandSection] = []
        let isBrowsing = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isBrowsing {
            let now = Date.now
            let locallyFrequent = commands
                .filter { frecency[$0.id] != nil }
                .sorted {
                    let left = frecencyScore(for: $0, now: now)
                    let right = frecencyScore(for: $1, now: now)
                    return left == right ? stableCommandOrder($0, $1) : left > right
                }
            let serverFrequent = commands
                .filter { $0.globalPopularityRank != nil }
                .sorted {
                    let left = $0.globalPopularityRank ?? .max
                    let right = $1.globalPopularityRank ?? .max
                    return left == right ? stableCommandOrder($0, $1) : left < right
                }
            var seen = Set<String>()
            let frequent = (locallyFrequent + serverFrequent)
                .filter { seen.insert($0.id).inserted }
                .prefix(5)
            result.append(
                ApplicationCommandSection(
                    kind: .frequentlyUsed, title: "Frequently Used",
                    application: nil, commands: Array(frequent)
                )
            )
        }
        let frequentIDs = Set(result.flatMap(\.commands).map(\.id))
        let rankedByApplication = Dictionary(grouping: ranked, by: { $0.application.id })
        for application in applications {
            var values = (rankedByApplication[application.id] ?? []).filter {
                !frequentIDs.contains($0.id)
            }
            if isBrowsing {
                values.sort(by: stableCommandOrder)
            }
            guard !values.isEmpty else { continue }
            result.append(
                ApplicationCommandSection(
                    kind: .application(application.id), title: application.name,
                    application: application, commands: values
                )
            )
        }
        return result
    }

    func pickerCommandOrder(query: String) -> [ApplicationCommand] {
        sections(query: query).flatMap(\.commands)
    }

    private func recordUse(of command: ApplicationCommand) {
        let previous = frecency[command.id]
        frecency[command.id] = FrecencyRecord(
            count: (previous?.count ?? 0) + 1, lastUsed: .now
        )
        if let data = try? JSONEncoder().encode(frecency) {
            UserDefaults.standard.set(data, forKey: frecencyDefaultsKey)
        }
    }

    private func frecencyScore(
        for command: ApplicationCommand,
        now: Date = .now
    ) -> Double {
        guard let record = frecency[command.id] else { return 0 }
        let ageDays = max(0, now.timeIntervalSince(record.lastUsed) / 86_400)
        return Double(record.count) * 10 + max(0, 30 - ageDays)
    }

    private func draftText(
        for value: ApplicationCommandArgument,
        option: ApplicationCommandOption
    ) -> String {
        switch value {
        case let .string(value):
            return option.choices.first(where: { $0.value == .string(value) })?.displayName ?? value
        case let .integer(value):
            return option.choices.first(where: { $0.value == .integer(value) })?.displayName
                ?? String(value)
        case let .number(value):
            return option.choices.first(where: { $0.value == .number(value) })?.displayName
                ?? value.formatted(.number)
        case let .boolean(value): return value ? "True" : "False"
        case let .user(value): return "@\(value.description)"
        case let .channel(value): return "#\(value.description)"
        case let .role(value): return "@\(value.description)"
        case let .mentionable(value): return "@\(value)"
        case let .attachment(url): return url.lastPathComponent
        }
    }

    private func stableCommandOrder(_ lhs: ApplicationCommand, _ rhs: ApplicationCommand) -> Bool {
        let nameComparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
        if nameComparison != .orderedSame { return nameComparison == .orderedAscending }
        let appComparison = lhs.application.name.localizedStandardCompare(rhs.application.name)
        if appComparison != .orderedSame { return appComparison == .orderedAscending }
        return lhs.id < rhs.id
    }

    private func searchScore(
        query: String, path: String, application: String, description: String
    ) -> Int? {
        if path == query { return 10_000 }
        if path.hasPrefix(query) { return 9_000 - max(0, path.count - query.count) }
        let queryTokens = query.split(separator: " ")
        let pathTokens = path.split(separator: " ")
        if queryTokens.allSatisfy({ queryToken in
            pathTokens.contains(where: { $0.hasPrefix(queryToken) })
        }) {
            return 8_000 - max(0, path.count - query.count)
        }
        if let range = path.range(of: query) {
            return 7_000 - path.distance(from: path.startIndex, to: range.lowerBound)
        }
        if let score = subsequenceScore(query: query, candidate: path) {
            return 6_000 + score
        }
        if application.contains(query) { return 4_000 }
        if description.contains(query) { return 2_000 }
        return nil
    }

    private func subsequenceScore(query: String, candidate: String) -> Int? {
        var candidateIndex = candidate.startIndex
        var gap = 0
        for character in query {
            guard let match = candidate[candidateIndex...].firstIndex(of: character) else { return nil }
            gap += candidate.distance(from: candidateIndex, to: match)
            candidateIndex = candidate.index(after: match)
        }
        return max(0, 500 - gap)
    }

    private func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ApplicationCommandAvailability {
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
                  let applicationBotID = command.application.bot?.id,
                  channel.recipients.contains(where: { $0.id == applicationBotID })
        {
            requiredContext = 1
        } else {
            requiredContext = 2
        }
        if !command.contexts.isEmpty,
           !command.contexts.contains(requiredContext)
        {
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

private extension ApplicationCommandExecutionState {
    var nonce: String {
        switch self {
        case let .queued(nonce), let .created(nonce, _), let .succeeded(nonce),
             let .failed(nonce, _):
            nonce
        }
    }
}
