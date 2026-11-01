import AppKit
import SakuraCordModels
import SwiftUI

struct ApplicationCommandSuggestion: Identifiable, Hashable {
    enum LeadingVisual: Hashable {
        case none
        case symbol(String)
        case user(name: String, avatarURL: URL?, status: PresenceStatus)
        case role(colorHex: UInt32?, iconURL: URL?, unicodeEmoji: String?)
    }

    enum Action: Hashable {
        case value(ApplicationCommandArgument, display: String)
        case addOption(ApplicationCommandOption)
        case chooseAttachment
    }

    let id: String
    let title: String
    var detail: String?
    var leadingVisual: LeadingVisual = .none
    var titleColorHex: UInt32?
    var isRole = false
    let action: Action
}

/// The list above an active command, styled like Discord's: a section title,
/// then options, choices or entities.
struct ApplicationCommandSuggestionContent: Equatable {
    enum Status: Equatable {
        case ready
        case loading
        case message(String, isError: Bool)
    }

    var title: String
    var suggestions: [ApplicationCommandSuggestion]
    var status: Status = .ready
    /// Discord highlights the first row only once something narrows the list.
    var highlightsFirst = true

    var isEmpty: Bool {
        suggestions.isEmpty && status == .ready
    }

    var defaultIndex: Int? {
        highlightsFirst && !suggestions.isEmpty ? 0 : nil
    }
}

enum ApplicationCommandSuggestionFactory {
    static let limit = 25

    static func content(
        draft: ApplicationCommandDraft,
        autocomplete: ApplicationCommandAutocompleteStatus,
        members: [Member],
        roles: [GuildRole],
        channels: [Channel]
    ) -> ApplicationCommandSuggestionContent? {
        switch draft.focus {
        case .command:
            return nil
        case .gap:
            let query = draft.gapText.trimmingCharacters(in: .whitespaces)
            let options = draft.matchingOptions(matching: query)
            guard !options.isEmpty else { return nil }
            return ApplicationCommandSuggestionContent(
                title: matchingTitle("Options", query: query),
                suggestions: options.map { option in
                    ApplicationCommandSuggestion(
                        id: "option:\(option.id)",
                        title: option.displayName,
                        detail: option.displayDescription.isEmpty ? nil : option.displayDescription,
                        action: .addOption(option)
                    )
                },
                highlightsFirst: !query.isEmpty
            )
        case let .field(id):
            guard let field = draft.field(id) else { return nil }
            return fieldContent(
                field, autocomplete: autocomplete, members: members, roles: roles, channels: channels
            )
        }
    }

    private static func autocompleteContent(
        _ base: ApplicationCommandSuggestionContent, status autocomplete: ApplicationCommandAutocompleteStatus
    ) -> ApplicationCommandSuggestionContent? {
        var content = base
        content.suggestions = autocomplete.choices.prefix(limit).map(choiceSuggestion)
        switch autocomplete {
        case .idle:
            return nil
        case .loading where content.suggestions.isEmpty:
            content.status = .loading
        case .loaded([]):
            content.status = .message("No options match your search", isError: false)
        case let .failed(message):
            content.status = .message(message.isEmpty ? "Loading options failed" : message, isError: true)
        default:
            break
        }
        return content
    }

    private static func fieldContent(
        _ field: ApplicationCommandDraftField,
        autocomplete: ApplicationCommandAutocompleteStatus,
        members: [Member],
        roles: [GuildRole],
        channels: [Channel]
    ) -> ApplicationCommandSuggestionContent? {
        let option = field.option
        // Chosen entities reopen the full list; editable choice labels remain queries.
        let query = field.isAtomic ? "" : lookupQuery(field.text, type: option.type)
        var content = ApplicationCommandSuggestionContent(
            title: matchingTitle("Options", query: query), suggestions: []
        )

        if option.usesAutocomplete, option.type.supportsAutocomplete {
            return autocompleteContent(content, status: autocomplete)
        }
        if !option.choices.isEmpty {
            content.suggestions = option.choices
                .filter { matches($0.displayName, $0.name, query: query) }
                .prefix(limit).map(choiceSuggestion)
            if content.suggestions.isEmpty {
                content.status = .message("No options match your search", isError: false)
            }
            return content
        }
        switch option.type {
        case .boolean:
            content.suggestions = [true, false].map { value in
                let title = value ? "True" : "False"
                return ApplicationCommandSuggestion(
                    id: "boolean:\(value)", title: title, action: .value(.boolean(value), display: title)
                )
            }.filter { matches($0.title, query: query) }
        case .user:
            content.title = matchingTitle("Members", query: query)
            content.suggestions = memberSuggestions(members, query: query, mentionable: false)
        case .mentionable:
            content.title = matchingTitle("Members and Roles", query: query)
            content.suggestions = memberSuggestions(members, query: query, mentionable: true)
                + roleSuggestions(roles, query: query, mentionable: true)
        case .role:
            content.title = matchingTitle("Roles", query: query)
            content.suggestions = roleSuggestions(roles, query: query, mentionable: false)
        case .channel:
            content.title = matchingTitle("Channels", query: query)
            content.suggestions = channels.filter { channel in
                (option.channelTypes.isEmpty || option.channelTypes.contains(channel.discordCommandType))
                    && (matches(channel.name, query: query) || matches(channel.category, query: query))
            }.prefix(limit).map { channel in
                ApplicationCommandSuggestion(
                    id: "channel:\(channel.id)", title: channel.name, detail: channel.category,
                    leadingVisual: .symbol(ChannelIconPresentation.systemImage(for: channel.kind, isHidden: false)),
                    action: .value(.channel(channel.id), display: "#\(channel.name)")
                )
            }
        case .attachment:
            content.title = "Attachment"
            content.suggestions = [
                ApplicationCommandSuggestion(
                    id: "attachment",
                    title: field.resolved == nil ? "Upload a file" : "Replace file",
                    detail: "Or paste or drop one here",
                    leadingVisual: .symbol("arrow.up.doc"),
                    action: .chooseAttachment
                )
            ]
            return content
        default:
            // Free text and numbers have no list; the help strip describes them.
            return nil
        }
        if content.suggestions.isEmpty {
            content.status = .message(
                query.isEmpty ? "Nothing to choose from here" : "No results for “\(query)”", isError: false
            )
        }
        return content
    }

    private static func memberSuggestions(
        _ members: [Member], query: String, mentionable: Bool
    ) -> [ApplicationCommandSuggestion] {
        members.filter {
            matches($0.user.displayName, $0.user.username, query: query)
        }.prefix(limit).map { member in
            ApplicationCommandSuggestion(
                id: "user:\(member.user.id)",
                title: member.user.displayName,
                detail: member.user.username,
                leadingVisual: .user(
                    name: member.user.displayName,
                    avatarURL: member.guildAvatarURL ?? member.user.avatarURL,
                    status: member.status
                ),
                action: .value(
                    mentionable ? .mentionable(member.user.id.description) : .user(member.user.id),
                    display: "@\(member.user.displayName)"
                )
            )
        }
    }

    private static func roleSuggestions(
        _ roles: [GuildRole], query: String, mentionable: Bool
    ) -> [ApplicationCommandSuggestion] {
        roles.filter { matches($0.name, query: query) }
            .sorted { $0.position > $1.position }
            .prefix(limit)
            .map { role in
                // @everyone's name already carries its sigil.
                let name = role.name.hasPrefix("@") ? role.name : "@\(role.name)"
                return ApplicationCommandSuggestion(
                    id: "role:\(role.id)",
                    title: name,
                    leadingVisual: .role(
                        colorHex: role.colorHex, iconURL: role.iconURL, unicodeEmoji: role.unicodeEmoji
                    ),
                    titleColorHex: role.colorHex,
                    isRole: true,
                    action: .value(
                        mentionable ? .mentionable(role.id.description) : .role(role.id),
                        display: name
                    )
                )
            }
    }

    private static func choiceSuggestion(_ choice: ApplicationCommandChoice) -> ApplicationCommandSuggestion {
        ApplicationCommandSuggestion(
            id: "choice:\(choice.id)",
            title: choice.displayName,
            action: .value(ApplicationCommandDraft.argument(for: choice.value), display: choice.displayName)
        )
    }

    private static func matchingTitle(_ title: String, query: String) -> String {
        query.isEmpty ? title : "\(title) matching \(query)"
    }

    static func usefulDescription(_ option: ApplicationCommandOption) -> String? {
        let description = option.displayDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty,
              description.caseInsensitiveCompare(option.displayName) != .orderedSame
        else { return nil }
        return description
    }

    private static func lookupQuery(_ text: String, type: ApplicationCommandOptionType) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard [.user, .role, .channel, .mentionable].contains(type),
              trimmed.hasPrefix("@") || trimmed.hasPrefix("#")
        else { return trimmed }
        return String(trimmed.dropFirst())
    }

    private static func matches(_ values: String?..., query: String) -> Bool {
        query.isEmpty || values.compactMap { $0 }.contains {
            $0.localizedCaseInsensitiveContains(query)
        }
    }
}

/// The strip inside the composer while a command is active: the focused
/// option's name and help, or the command's when the caret is between chips.
struct ApplicationCommandHelpStrip: View {
    let draft: ApplicationCommandDraft
    let issue: ApplicationCommandFieldIssue?
    let cancel: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: InterfaceScale.metric(7)) {
            Text(title)
                .font(.interface(.callout).weight(.semibold))
                .lineLimit(1)
                .layoutPriority(1)
            if let issue = visibleIssue {
                Label(issue, systemImage: "exclamationmark.circle.fill")
                    .font(.interface(.callout))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            } else if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.interface(.callout))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: InterfaceScale.metric(8))
            HoverActionButton(systemImage: "xmark", help: "Cancel command", diameter: InterfaceScale.metric(22), action: cancel)
                .foregroundStyle(.secondary)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
        }
        .padding(.leading, InterfaceScale.metric(15))
        .padding(.trailing, InterfaceScale.metric(8))
        .padding(.top, InterfaceScale.metric(8))
        .padding(.bottom, InterfaceScale.metric(6))
        .accessibilityElement(children: .combine)
    }

    private var focusedOption: ApplicationCommandOption? {
        draft.focusedField?.option
    }

    private var title: String {
        focusedOption?.displayName ?? "/\(draft.command.displayName)"
    }

    private var detail: String? {
        guard let option = focusedOption else { return draft.command.displayDescription }
        return option.displayDescription
    }

    private var visibleIssue: String? {
        guard let issue, draft.focusedField?.id == issue.fieldID else { return nil }
        return issue.message
    }
}

/// The list above an active command.
struct ApplicationCommandSuggestionPanel: View {
    let content: ApplicationCommandSuggestionContent
    let selectedIndex: Int?
    let select: (ApplicationCommandSuggestion) -> Void
    let highlight: (Int) -> Void

    var cornerRadius: CGFloat = ChatChromeMetrics.composerCornerRadius
    var keyboardSelectionRevision = 0

    var body: some View {
        ComposerOptionPanel(
            title: content.title,
            rows: content.suggestions,
            selectedIndex: selectedIndex,
            status: content.status,
            cornerRadius: cornerRadius,
            keyboardSelectionRevision: keyboardSelectionRevision,
            select: select,
            highlight: highlight,
            accessibilityLabel: { [$0.title, $0.detail].compactMap { $0 }.joined(separator: ", ") },
            label: { suggestion in
                if suggestion.leadingVisual != .none {
                    ApplicationCommandSuggestionIcon(visual: suggestion.leadingVisual)
                        .frame(width: InterfaceScale.metric(22), height: InterfaceScale.metric(22))
                }
                Text(suggestion.title)
                    .foregroundStyle(
                        suggestion.isRole
                            ? SakuraCordAccentColor.color(forRoleColorHex: suggestion.titleColorHex)
                            : .primary
                    )
                    .lineLimit(1)
                Spacer(minLength: InterfaceScale.metric(12))
                if let detail = suggestion.detail, !detail.isEmpty {
                    ComposerOptionDetail(detail)
                }
            }
        )
    }
}

/// The composer's option menu: a section title, then rows with an inset
/// highlight concentric with the panel, navigated by the keyboard with room
/// to spare at the edges. Command arguments and emoji share it.
struct ComposerOptionPanel<Row: Identifiable, Label: View>: View where Row.ID == String {
    let title: String
    let rows: [Row]
    let selectedIndex: Int?
    var status: ApplicationCommandSuggestionContent.Status = .ready
    var cornerRadius: CGFloat = ChatChromeMetrics.composerCornerRadius
    var keyboardSelectionRevision = 0
    let select: (Row) -> Void
    let highlight: (Int) -> Void
    let accessibilityLabel: (Row) -> String
    @ViewBuilder let label: (Row) -> Label

    private static var rowHeight: CGFloat { InterfaceScale.metric(34) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.interface(.caption).weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, InterfaceScale.metric(14))
                .padding(.top, InterfaceScale.metric(10))
                .padding(.bottom, InterfaceScale.metric(5))
            if !rows.isEmpty {
                ComposerSuggestionList(
                    rows: rows,
                    selectedID: selectedIndex.flatMap { rows.indices.contains($0) ? rows[$0].id : nil },
                    keyboardSelectionRevision: keyboardSelectionRevision,
                    maximumHeight: 320,
                    rowHeight: { _ in Self.rowHeight },
                    highlight: { row in
                        if let index = rows.firstIndex(where: { $0.id == row.id }), index != selectedIndex { highlight(index) }
                    },
                    activate: select,
                    content: { row in
                        let isSelected = rows.firstIndex(where: { $0.id == row.id }) == selectedIndex
                        Button { select(row) } label: {
                            // Every row spans the panel, whether or not its
                            // label ends in a spacer.
                            HStack(spacing: InterfaceScale.metric(8)) { label(row) }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, InterfaceScale.metric(8))
                                .frame(height: Self.rowHeight)
                                .background(
                                    isSelected ? Color.primary.opacity(0.10) : .clear,
                                    in: RoundedRectangle(cornerRadius: max(0, cornerRadius - 6), style: .continuous)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .accessibilityLabel(accessibilityLabel(row))
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                )
                .padding(.bottom, InterfaceScale.metric(6))
            }
            statusView
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .commandPanelSurface(cornerRadius: cornerRadius)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .ready:
            EmptyView()
        case .loading:
            HStack(spacing: InterfaceScale.metric(8)) {
                InteractionLoadingDotsView()
                Text("Loading options…")
            }
            .font(.interface(.callout))
            .foregroundStyle(.secondary)
            .padding(.horizontal, InterfaceScale.metric(14))
            .padding(.bottom, InterfaceScale.metric(12))
        case let .message(text, isError):
            Text(text)
                .font(.interface(.callout))
                .foregroundStyle(isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .padding(.horizontal, InterfaceScale.metric(14))
                .padding(.bottom, InterfaceScale.metric(12))
        }
    }
}

/// A row's trailing, secondary text.
struct ComposerOptionDetail: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.interface(.caption))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: InterfaceScale.metric(320), alignment: .trailing)
    }
}

private struct ApplicationCommandSuggestionIcon: View {
    let visual: ApplicationCommandSuggestion.LeadingVisual

    var body: some View {
        switch visual {
        case .none:
            EmptyView()
        case let .symbol(name):
            Image(systemName: name)
                .font(.interfaceSystem(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
        case let .user(name, avatarURL, status):
            AvatarPresenceView(status: status, avatarSize: InterfaceScale.metric(22), indicatorSize: InterfaceScale.metric(7)) {
                AvatarView(name: name, url: avatarURL, size: InterfaceScale.metric(22))
            }
        case let .role(colorHex, iconURL, unicodeEmoji):
            if let iconURL {
                AnimatedRemoteImage(url: iconURL).frame(width: InterfaceScale.metric(18), height: InterfaceScale.metric(18))
            } else if let unicodeEmoji, !unicodeEmoji.isEmpty {
                Text(unicodeEmoji).font(.interfaceSystem(size: 15))
            } else {
                RoleColorIndicator(colorHex: colorHex, size: InterfaceScale.metric(12))
            }
        }
    }
}
