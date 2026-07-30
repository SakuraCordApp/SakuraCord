import AppKit
import SakuraCordModels
import SwiftUI
import UniformTypeIdentifiers

struct ApplicationCommandPickerView: View {
    let composer: ApplicationCommandComposerModel
    let choose: (ApplicationCommand) -> Void
    let dismiss: () -> Void
    @State private var visibleSection = ApplicationCommandPickerSection.frequent

    var body: some View {
        let sections = composer.sections(query: composer.searchText)
        ScrollViewReader { proxy in
            HStack(alignment: .top, spacing: 0) {
                ApplicationCommandSectionRail(
                    sections: sections,
                    visibleSection: visibleSection,
                    jump: { section in
                        visibleSection = section
                        if let modelSection = sections.first(where: { $0.pickerSection == section }) {
                            composer.selectedCommandID = modelSection.commands.first?.id
                        }
                        proxy.scrollTo(ApplicationCommandPickerDocumentRow.headerID(for: section), anchor: .top)
                    }
                )
                Divider()
                ApplicationCommandPickerResults(
                    sections: sections,
                    selectedCommandID: composer.selectedCommandID,
                    isLoading: composer.isLoading,
                    error: composer.loadError,
                    select: choose,
                    highlight: { commandID in
                        composer.selectedCommandID = commandID
                    },
                    becameVisible: { visibleSection = $0 }
                )
            }
            .onChange(of: composer.pickerKeyboardSelectionRevision) { _, _ in
                guard let commandID = composer.selectedCommandID else { return }
                proxy.scrollTo(
                    ApplicationCommandPickerDocumentRow.commandID(commandID),
                    anchor: .center
                )
            }
        }
        .padding(5)
        .frame(maxWidth: .infinity, minHeight: 190, maxHeight: 340)
        .glassEffect(
            .regular.interactive(),
            in: ConcentricRectangle(
                corners: .concentric(
                    minimum: .fixed(
                        ChatChromeMetrics.composerMinimumCornerRadius
                    )
                ),
                isUniform: true
            )
        )
        .containerShape(
            .rect(
                cornerRadius: ChatChromeMetrics.composerMinimumCornerRadius,
                style: .continuous
            )
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Application commands")
        .onExitCommand(perform: dismiss)
    }
}

private enum ApplicationCommandPickerSection: Hashable, Identifiable {
    case frequent
    case application(String)

    var id: String {
        switch self {
        case .frequent: "frequent"
        case let .application(id): "application:\(id)"
        }
    }
}

private struct ApplicationCommandSectionRail: View {
    let sections: [ApplicationCommandSection]
    let visibleSection: ApplicationCommandPickerSection
    let jump: (ApplicationCommandPickerSection) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(sections) { section in
                    switch section.kind {
                    case .frequentlyUsed:
                        PickerSectionBookmark(
                            section: section.pickerSection,
                            visibleSection: visibleSection,
                            help: section.title,
                            jump: jump
                        ) {
                            Image(systemName: "clock.fill")
                                .foregroundStyle(.secondary)
                        }
                    case .application:
                        PickerSectionBookmark(
                            section: section.pickerSection,
                            visibleSection: visibleSection,
                            help: section.title,
                            jump: jump
                        ) {
                            CommandApplicationIcon(application: section.application, size: 28)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollIndicators(.hidden)
        .frame(width: PickerSectionRailLayout.width)
    }
}

private struct ApplicationCommandPickerDocumentRow: Identifiable {
    enum Content {
        case header(section: ApplicationCommandPickerSection, title: String, count: Int)
        case command(ApplicationCommand)
    }

    let id: String
    let content: Content

    static func headerID(for section: ApplicationCommandPickerSection) -> String {
        "command-header:\(section.id)"
    }

    static func commandID(_ commandID: String) -> String {
        "command:\(commandID)"
    }
}

private struct ApplicationCommandPickerResults: View {
    let sections: [ApplicationCommandSection]
    let selectedCommandID: String?
    let isLoading: Bool
    let error: String?
    let select: (ApplicationCommand) -> Void
    let highlight: (String) -> Void
    let becameVisible: (ApplicationCommandPickerSection) -> Void

    private var rows: [ApplicationCommandPickerDocumentRow] {
        sections.flatMap { section in
            [
                ApplicationCommandPickerDocumentRow(
                    id: ApplicationCommandPickerDocumentRow.headerID(for: section.pickerSection),
                    content: .header(
                        section: section.pickerSection,
                        title: section.title,
                        count: section.commands.count
                    )
                )
            ] + section.commands.map { command in
                ApplicationCommandPickerDocumentRow(
                    id: ApplicationCommandPickerDocumentRow.commandID(command.id),
                    content: .command(command)
                )
            }
        }
    }

    var body: some View {
        if isLoading, sections.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading commands…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error, sections.isEmpty {
            ContentUnavailableView(
                "Commands unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if sections.isEmpty {
            ContentUnavailableView(
                "No matching commands",
                systemImage: "command",
                description: Text("Try another command or application name.")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        ApplicationCommandPickerDocumentRowView(
                            row: row,
                            selectedCommandID: selectedCommandID,
                            select: select,
                            highlight: highlight,
                            becameVisible: becameVisible
                        )
                        .id(row.id)
                    }
                }
                .padding(.horizontal, 5)
            }
        }
    }
}

private struct ApplicationCommandPickerDocumentRowView: View {
    let row: ApplicationCommandPickerDocumentRow
    let selectedCommandID: String?
    let select: (ApplicationCommand) -> Void
    let highlight: (String) -> Void
    let becameVisible: (ApplicationCommandPickerSection) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch row.content {
            case let .header(section, title, count):
                HStack {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(count, format: .number)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8)
                .padding(.top, 9)
                .padding(.bottom, 4)
                .onAppear { becameVisible(section) }
            case let .command(command):
                ApplicationCommandPickerRow(
                    command: command,
                    isSelected: command.id == selectedCommandID,
                    select: { select(command) },
                    highlight: { highlight(command.id) }
                )
            }
        }
    }
}

private struct ApplicationCommandPickerRow: View {
    let command: ApplicationCommand
    let isSelected: Bool
    let select: () -> Void
    let highlight: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                CommandApplicationIcon(application: command.application, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("/\(command.displayName)")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(command.displayDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 10)
                Text(command.application.name)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .background {
            ConcentricRectangle(
                cornerRadius: 7,
                style: .continuous
            )
                .fill(isSelected ? Color.primary.opacity(0.13) : .clear)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            guard hovering else { return }
            highlight()
        }
        .accessibilityIdentifier("application-command-\(command.id)")
        .accessibilityLabel("/\(command.displayName), \(command.displayDescription), by \(command.application.name)")
    }
}

private extension ApplicationCommandSection {
    var pickerSection: ApplicationCommandPickerSection {
        switch kind {
        case .frequentlyUsed: .frequent
        case let .application(id): .application(id)
        }
    }
}

struct ApplicationCommandEditorView: View {
    let composer: ApplicationCommandComposerModel
    let members: [Member]
    let channels: [Channel]
    let requestAutocomplete: (ApplicationCommandOption, String) -> Void
    let execute: () -> Void
    let cancel: () -> Void

    @ViewBuilder var body: some View {
        if let command = composer.activeCommand {
            let displayedOptions = composer.displayedOptions
            VStack(alignment: .leading, spacing: 8) {
                ApplicationCommandActiveHeader(command: command, cancel: cancel)
                ForEach(displayedOptions) { option in
                    ApplicationCommandOptionEditor(
                        option: option,
                        value: composer.value(for: option),
                        members: members,
                        channels: channels,
                        autocompleteChoices: composer.focusedOptionID == option.id
                            ? composer.autocompleteChoices : [],
                        isAutocompleteLoading: composer.focusedOptionID == option.id
                            && composer.isAutocompleteLoading,
                        autocompleteError: composer.focusedOptionID == option.id
                            ? composer.autocompleteError : nil,
                        validationError: composer.validationError(for: option),
                        setValue: { composer.setValue($0, for: option) },
                        focus: { composer.focus(option) },
                        requestAutocomplete: { requestAutocomplete(option, $0) },
                        remove: option.isRequired ? nil : { composer.removeOptionalOption(option) }
                    )
                }
                ApplicationCommandEditorFooter(
                    composer: composer,
                    execute: execute
                )
            }
            .padding(10)
            .background(
                .regularMaterial,
                in: ConcentricRectangle(
                    cornerRadius: ChatChromeMetrics.controlCornerRadius, style: .continuous
                )
            )
            .overlay {
                ConcentricRectangle(
                    cornerRadius: ChatChromeMetrics.controlCornerRadius, style: .continuous
                )
                .stroke(.primary.opacity(0.12), lineWidth: 1)
            }
            .onExitCommand(perform: cancel)
        }
    }
}

private struct ApplicationCommandActiveHeader: View {
    let command: ApplicationCommand
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            CommandApplicationIcon(application: command.application, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("/\(command.displayName)")
                    .font(.headline)
                    .lineLimit(1)
                Text(command.displayDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Text(command.application.name)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button(action: cancel) {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Cancel command")
        }
    }
}

private struct ApplicationCommandEditorFooter: View {
    let composer: ApplicationCommandComposerModel
    let execute: () -> Void

    var body: some View {
        let availableOptionalOptions = composer.availableOptionalOptions
        HStack(spacing: 8) {
            if !availableOptionalOptions.isEmpty {
                Menu {
                    ForEach(availableOptionalOptions) { option in
                        Button {
                            composer.addOptionalOption(option)
                        } label: {
                            Label(option.displayName, systemImage: optionSymbol(option.type))
                        }
                    }
                } label: {
                    Label(
                        "+\(availableOptionalOptions.count) more",
                        systemImage: "plus.circle"
                    )
                    .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if let progress = composer.executionProgress {
                ApplicationCommandProgressLabel(progress: progress)
            } else if let error = composer.executionError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
            Button(action: execute) {
                Label("Run command", systemImage: "paperplane.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!composer.canSubmit || composer.executionProgress != nil)
            .keyboardShortcut(.return, modifiers: [.command])
        }
    }

    private func optionSymbol(_ type: ApplicationCommandOptionType) -> String {
        switch type {
        case .user: "person"
        case .channel: "number"
        case .role: "person.badge.shield.checkmark"
        case .mentionable: "at"
        case .attachment: "paperclip"
        case .boolean: "checkmark.circle"
        case .integer, .number: "number.circle"
        default: "text.cursor"
        }
    }
}

private struct ApplicationCommandProgressLabel: View {
    let progress: ApplicationCommandProgress

    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(label).lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var label: String {
        switch progress {
        case .preparing: "Preparing…"
        case let .reserving(files): "Reserving \(files) file\(files == 1 ? "" : "s")…"
        case let .uploading(fileName, _, _): "Uploading \(fileName)…"
        case .submitting: "Running command…"
        case .awaitingResponse: "Waiting for the app…"
        }
    }
}

private struct ApplicationCommandOptionEditor: View {
    let option: ApplicationCommandOption
    let value: ApplicationCommandArgument?
    let members: [Member]
    let channels: [Channel]
    let autocompleteChoices: [ApplicationCommandChoice]
    let isAutocompleteLoading: Bool
    let autocompleteError: String?
    let validationError: String?
    let setValue: (ApplicationCommandArgument?) -> Void
    let focus: () -> Void
    let requestAutocomplete: (String) -> Void
    let remove: (() -> Void)?
    @State private var autocompleteSelection = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(option.displayName)
                    .font(.caption.weight(.semibold))
                if option.isRequired {
                    Text("Required")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let remove {
                    Button(action: remove) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove \(option.displayName)")
                }
            }
            optionControl
            if !option.displayDescription.isEmpty {
                Text(option.displayDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let validationError, value != nil {
                Label(validationError, systemImage: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            if isAutocompleteLoading {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text("Loading suggestions…")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else if let autocompleteError {
                Text(autocompleteError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            } else if !autocompleteChoices.isEmpty {
                CommandAutocompleteChoiceList(
                    choices: autocompleteChoices,
                    selectedIndex: autocompleteSelection,
                    select: { choice in
                        setValue(argument(for: choice.value))
                    }
                )
            }
        }
        .padding(8)
        .background(.primary.opacity(0.055), in: ConcentricRectangle(cornerRadius: 8))
        .onTapGesture(perform: focus)
        .onChange(of: autocompleteChoices) { _, choices in
            autocompleteSelection = min(autocompleteSelection, max(0, choices.count - 1))
        }
    }

    @ViewBuilder
    private var optionControl: some View {
        switch option.type {
        case .string:
            if option.choices.isEmpty {
                CommandTextOptionEditor(
                    initialValue: stringValue,
                    placeholder: option.displayName,
                    onChange: { text in
                        setValue(text.isEmpty && !option.isRequired ? nil : .string(text))
                        if option.usesAutocomplete { requestAutocomplete(text) }
                    },
                    onFocus: focus,
                    onMove: moveAutocomplete,
                    onSubmit: acceptAutocomplete
                )
            } else {
                CommandChoicePicker(
                    choices: option.choices,
                    selected: choiceValue,
                    select: { setValue(argument(for: $0.value)) }
                )
            }
        case .integer:
            if option.choices.isEmpty {
                CommandTextOptionEditor(
                    initialValue: integerValue,
                    placeholder: option.displayName,
                    onChange: { text in
                        setValue(Int64(text).map(ApplicationCommandArgument.integer))
                        if option.usesAutocomplete { requestAutocomplete(text) }
                    },
                    onFocus: focus,
                    onMove: moveAutocomplete,
                    onSubmit: acceptAutocomplete
                )
            } else {
                CommandChoicePicker(
                    choices: option.choices,
                    selected: choiceValue,
                    select: { setValue(argument(for: $0.value)) }
                )
            }
        case .number:
            if option.choices.isEmpty {
                CommandTextOptionEditor(
                    initialValue: numberValue,
                    placeholder: option.displayName,
                    onChange: { text in
                        let normalized = text.replacingOccurrences(
                            of: Locale.current.decimalSeparator ?? ".", with: "."
                        )
                        setValue(Double(normalized).flatMap {
                            $0.isFinite ? .number($0) : nil
                        })
                        if option.usesAutocomplete { requestAutocomplete(text) }
                    },
                    onFocus: focus,
                    onMove: moveAutocomplete,
                    onSubmit: acceptAutocomplete
                )
            } else {
                CommandChoicePicker(
                    choices: option.choices,
                    selected: choiceValue,
                    select: { setValue(argument(for: $0.value)) }
                )
            }
        case .boolean:
            Picker(option.displayName, selection: booleanBinding) {
                Text("Choose…").tag(Bool?.none)
                Text("True").tag(Bool?.some(true))
                Text("False").tag(Bool?.some(false))
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        case .user:
            CommandEntityOptionEditor(
                title: option.displayName,
                selection: entitySelection,
                candidates: userCandidates,
                setValue: setValue
            )
        case .channel:
            CommandEntityOptionEditor(
                title: option.displayName,
                selection: entitySelection,
                candidates: channelCandidates,
                setValue: setValue
            )
        case .role:
            CommandEntityOptionEditor(
                title: option.displayName,
                selection: entitySelection,
                candidates: roleCandidates,
                setValue: setValue
            )
        case .mentionable:
            CommandEntityOptionEditor(
                title: option.displayName,
                selection: entitySelection,
                candidates: userCandidates + roleCandidates.map {
                    CommandEntityCandidate(
                        id: "mentionable-role:\($0.id)", title: $0.title,
                        subtitle: $0.subtitle, systemImage: $0.systemImage,
                        argument: mentionableArgument($0.argument)
                    )
                },
                setValue: setValue
            )
        case .attachment:
            CommandAttachmentOptionEditor(value: value, setValue: setValue)
        default:
            Label(
                "Unsupported option type \(option.type.rawValue)",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }

    private var stringValue: String {
        guard case let .string(value)? = value else { return "" }
        return value
    }

    private var integerValue: String {
        guard case let .integer(value)? = value else { return "" }
        return String(value)
    }

    private var numberValue: String {
        guard case let .number(value)? = value else { return "" }
        return value.formatted(.number)
    }

    private var choiceValue: ApplicationCommandChoiceValue? {
        switch value {
        case let .string(value): .string(value)
        case let .integer(value): .integer(value)
        case let .number(value): .number(value)
        default: nil
        }
    }

    private var booleanBinding: Binding<Bool?> {
        Binding(
            get: {
                guard case let .boolean(value)? = value else { return nil }
                return value
            },
            set: { setValue($0.map(ApplicationCommandArgument.boolean)) }
        )
    }

    private func argument(for value: ApplicationCommandChoiceValue) -> ApplicationCommandArgument {
        switch value {
        case let .string(value): .string(value)
        case let .integer(value): .integer(value)
        case let .number(value): .number(value)
        }
    }

    private var entitySelection: String? {
        switch value {
        case let .user(value): "user:\(value)"
        case let .channel(value): "channel:\(value)"
        case let .role(value): "role:\(value)"
        case let .mentionable(value): "mentionable:\(value)"
        default: nil
        }
    }

    private var userCandidates: [CommandEntityCandidate] {
        members.map { member in
            CommandEntityCandidate(
                id: "user:\(member.user.id)", title: member.user.displayName,
                subtitle: "@\(member.user.username)", systemImage: "person.circle",
                argument: .user(member.user.id)
            )
        }
    }

    private var channelCandidates: [CommandEntityCandidate] {
        channels.filter { channel in
            option.channelTypes.isEmpty || option.channelTypes.contains(channel.discordCommandType)
        }.map { channel in
            CommandEntityCandidate(
                id: "channel:\(channel.id)", title: channel.name,
                subtitle: channel.category, systemImage: channel.kind == .voice ? "speaker.wave.2" : "number",
                argument: .channel(channel.id)
            )
        }
    }

    private var roleCandidates: [CommandEntityCandidate] {
        var rolesByID: [RoleID: GuildRole] = [:]
        for role in members.flatMap(\.roles) {
            rolesByID[role.id] = role
        }
        return rolesByID.values.sorted { $0.position > $1.position }.map { role in
            CommandEntityCandidate(
                id: "role:\(role.id)", title: role.name, subtitle: "Role",
                systemImage: "person.badge.shield.checkmark", argument: .role(role.id)
            )
        }
    }

    private func mentionableArgument(_ argument: ApplicationCommandArgument) -> ApplicationCommandArgument {
        switch argument {
        case let .role(value): .mentionable(value.description)
        case let .user(value): .mentionable(value.description)
        default: argument
        }
    }

    private func moveAutocomplete(_ direction: MoveCommandDirection) {
        guard !autocompleteChoices.isEmpty else { return }
        switch direction {
        case .up:
            autocompleteSelection = (
                autocompleteSelection - 1 + autocompleteChoices.count
            ) % autocompleteChoices.count
        case .down:
            autocompleteSelection = (autocompleteSelection + 1) % autocompleteChoices.count
        default:
            break
        }
    }

    private func acceptAutocomplete() {
        guard autocompleteChoices.indices.contains(autocompleteSelection) else { return }
        setValue(argument(for: autocompleteChoices[autocompleteSelection].value))
    }
}

private struct CommandTextOptionEditor: View {
    let initialValue: String
    let placeholder: String
    let onChange: (String) -> Void
    let onFocus: () -> Void
    let onMove: (MoveCommandDirection) -> Void
    let onSubmit: () -> Void
    @State private var text: String

    init(
        initialValue: String,
        placeholder: String,
        onChange: @escaping (String) -> Void,
        onFocus: @escaping () -> Void,
        onMove: @escaping (MoveCommandDirection) -> Void = { _ in },
        onSubmit: @escaping () -> Void = {}
    ) {
        self.initialValue = initialValue
        self.placeholder = placeholder
        self.onChange = onChange
        self.onFocus = onFocus
        self.onMove = onMove
        self.onSubmit = onSubmit
        _text = State(initialValue: initialValue)
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .padding(.horizontal, 8)
            .frame(minHeight: 30)
            .background(.background.opacity(0.55), in: ConcentricRectangle(cornerRadius: 6))
            .onChange(of: text) { _, value in onChange(value) }
            .onTapGesture(perform: onFocus)
            .onMoveCommand(perform: onMove)
            .onSubmit(onSubmit)
            .onChange(of: initialValue) { _, value in
                if value != text { text = value }
            }
    }
}

private struct CommandChoicePicker: View {
    let choices: [ApplicationCommandChoice]
    let selected: ApplicationCommandChoiceValue?
    let select: (ApplicationCommandChoice) -> Void

    var body: some View {
        Menu {
            ForEach(choices) { choice in
                Button {
                    select(choice)
                } label: {
                    if choice.value == selected {
                        Label(choice.displayName, systemImage: "checkmark")
                    } else {
                        Text(choice.displayName)
                    }
                }
            }
        } label: {
            HStack {
                Text(choices.first(where: { $0.value == selected })?.displayName ?? "Choose…")
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 30)
            .background(.background.opacity(0.55), in: ConcentricRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
    }
}

private struct CommandEntityCandidate: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String?
    let systemImage: String
    let argument: ApplicationCommandArgument
}

private struct CommandEntityOptionEditor: View {
    let title: String
    let selection: String?
    let candidates: [CommandEntityCandidate]
    let setValue: (ApplicationCommandArgument?) -> Void
    @State private var isPresented = false
    @State private var query = ""

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack {
                if let selected = candidates.first(where: { $0.id == selection }) {
                    Image(systemName: selected.systemImage)
                    Text(selected.title)
                } else {
                    Text("Choose \(title.lowercased())…")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 30)
            .background(.background.opacity(0.55), in: ConcentricRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            CommandEntityResolver(
                title: title, query: $query, candidates: filteredCandidates
            ) { candidate in
                setValue(candidate.argument)
                isPresented = false
            }
            .onExitCommand { isPresented = false }
        }
    }

    private var filteredCandidates: [CommandEntityCandidate] {
        guard !query.isEmpty else { return Array(candidates.prefix(50)) }
        return candidates.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.subtitle?.localizedCaseInsensitiveContains(query) == true
        }.prefix(50).map(\.self)
    }
}

private struct CommandEntityResolver: View {
    let title: String
    @Binding var query: String
    let candidates: [CommandEntityCandidate]
    let select: (CommandEntityCandidate) -> Void
    @FocusState private var searchFocused: Bool
    @State private var selectedIndex = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Choose \(title)")
                .font(.headline)
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onMoveCommand { direction in
                    guard !candidates.isEmpty else { return }
                    switch direction {
                    case .up:
                        selectedIndex = (selectedIndex - 1 + candidates.count) % candidates.count
                    case .down:
                        selectedIndex = (selectedIndex + 1) % candidates.count
                    default:
                        break
                    }
                }
                .onSubmit {
                    guard candidates.indices.contains(selectedIndex) else { return }
                    select(candidates[selectedIndex])
                }
            if candidates.isEmpty {
                ContentUnavailableView("No matches", systemImage: "magnifyingglass")
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(candidates.enumerated(), id: \.element.id) { index, candidate in
                            Button {
                                select(candidate)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: candidate.systemImage)
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(candidate.title)
                                        if let subtitle = candidate.subtitle {
                                            Text(subtitle)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                                .background(
                                    index == selectedIndex ? Color.primary.opacity(0.13) : .clear,
                                    in: ConcentricRectangle(cornerRadius: 5)
                                )
                            }
                            .buttonStyle(.plain)
                            .onHover { hovering in
                                if hovering { selectedIndex = index }
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 320, height: 300)
        .onAppear { searchFocused = true }
        .onChange(of: candidates) { _, values in
            selectedIndex = min(selectedIndex, max(0, values.count - 1))
        }
    }
}

private struct CommandAutocompleteChoiceList: View {
    let choices: [ApplicationCommandChoice]
    let selectedIndex: Int
    let select: (ApplicationCommandChoice) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(choices.enumerated(), id: \.element.id) { index, choice in
                Button {
                    select(choice)
                } label: {
                    HStack {
                        Image(systemName: "sparkle.magnifyingglass")
                        Text(choice.displayName)
                        Spacer()
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .background(
                        index == selectedIndex ? Color.primary.opacity(0.13) : .clear,
                        in: ConcentricRectangle(cornerRadius: 5)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(.background.opacity(0.65), in: ConcentricRectangle(cornerRadius: 6))
    }
}

private struct CommandAttachmentOptionEditor: View {
    let value: ApplicationCommandArgument?
    let setValue: (ApplicationCommandArgument?) -> Void
    @State private var showImporter = false
    @State private var isDropTarget = false

    var body: some View {
        Group {
            if case let .attachment(url)? = value {
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(url.lastPathComponent).lineLimit(1)
                        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        setValue(nil)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
                .background(.background.opacity(0.55), in: ConcentricRectangle(cornerRadius: 7))
            } else {
                Button {
                    showImporter = true
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "arrow.up.doc")
                            .font(.title2)
                        Text("Choose a file or drop it here")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity, minHeight: 72)
                    .background(
                        isDropTarget
                            ? AnyShapeStyle(Color.primary.opacity(0.13))
                            : AnyShapeStyle(.background.opacity(0.45)),
                        in: ConcentricRectangle(cornerRadius: 8)
                    )
                    .overlay {
                        ConcentricRectangle(cornerRadius: 8)
                            .stroke(
                                isDropTarget ? Color.primary : .secondary.opacity(0.45),
                                style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                            )
                            .padding(0.5)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .fileImporter(
            isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                setValue(.attachment(url))
            }
        }
        .dropDestination(for: URL.self, action: { urls, _ in
            guard let url = urls.first else { return false }
            setValue(.attachment(url))
            return true
        }, isTargeted: { isDropTarget = $0 })
    }
}

struct CommandApplicationIcon: View {
    let application: ApplicationCommandApplication?
    let size: CGFloat

    var body: some View {
        Group {
            if let url = application?.iconURL ?? application?.bot?.avatarURL {
                AnimatedRemoteImage(url: url)
            } else {
                ZStack {
                    Circle().fill(Color.secondary.opacity(0.18))
                    Text(application?.name.first.map(String.init) ?? "/")
                        .font(.system(size: size * 0.42, weight: .bold))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

extension Channel {
    var discordCommandType: Int {
        switch kind {
        case .text: 0
        case .directMessage: 1
        case .voice: 2
        case .groupDirectMessage: 3
        case .announcement: 5
        case .forum: 15
        case .unknown: -1
        }
    }
}
