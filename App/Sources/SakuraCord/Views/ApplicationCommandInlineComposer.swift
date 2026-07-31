import AppKit
import SakuraCordModels
import SwiftUI

struct ApplicationCommandSuggestion: Identifiable, Hashable {
    enum LeadingVisual: Hashable {
        case symbol(String)
        case user(
            name: String,
            avatarURL: URL?,
            decorationURL: URL?,
            status: PresenceStatus
        )
        case role(colorHex: UInt32?, iconURL: URL?, unicodeEmoji: String?)
    }

    enum Action: Hashable {
        case value(ApplicationCommandArgument, displayText: String)
        case chooseAttachment
        case addOption(ApplicationCommandOption)
    }

    let id: String
    let title: String
    let trailingText: String?
    let leadingVisual: LeadingVisual
    let action: Action

    init(
        id: String,
        title: String,
        trailingText: String? = nil,
        systemImage: String,
        action: Action
    ) {
        self.id = id
        self.title = title
        self.trailingText = trailingText
        leadingVisual = .symbol(systemImage)
        self.action = action
    }

    init(
        id: String,
        title: String,
        trailingText: String? = nil,
        leadingVisual: LeadingVisual,
        action: Action
    ) {
        self.id = id
        self.title = title
        self.trailingText = trailingText
        self.leadingVisual = leadingVisual
        self.action = action
    }
}

enum ApplicationCommandSuggestionFactory {
    static func heading(
        option: ApplicationCommandOption?,
        hasAutocompleteChoices: Bool
    ) -> String {
        guard let option else { return "Optional fields" }
        if hasAutocompleteChoices || !option.choices.isEmpty { return "Options" }
        return switch option.type {
        case .user: "Members"
        case .channel: "Channels"
        case .role: "Roles"
        case .mentionable: "Members and roles"
        case .attachment: "Attachments"
        case .boolean: "Options"
        default: "Suggestions"
        }
    }

    static func suggestions(
        option: ApplicationCommandOption?,
        query: String,
        members: [Member],
        roles: [GuildRole],
        channels: [Channel],
        autocompleteChoices: [ApplicationCommandChoice],
        availableOptions: [ApplicationCommandOption]
    ) -> [ApplicationCommandSuggestion] {
        let result: [ApplicationCommandSuggestion]
        if let option {
            result = values(
                for: option,
                query: query,
                members: members,
                roles: roles,
                channels: channels,
                autocompleteChoices: autocompleteChoices
            )
        } else {
            result = availableOptions.map { option in
                ApplicationCommandSuggestion(
                    id: "option:\(option.id)",
                    title: option.displayName,
                    trailingText: usefulOptionalFieldDescription(option),
                    systemImage: "plus.circle",
                    action: .addOption(option)
                )
            }
        }
        return Array(result.prefix(12))
    }

    private static func values(
        for option: ApplicationCommandOption,
        query: String,
        members: [Member],
        roles: [GuildRole],
        channels: [Channel],
        autocompleteChoices: [ApplicationCommandChoice]
    ) -> [ApplicationCommandSuggestion] {
        if !autocompleteChoices.isEmpty {
            return autocompleteChoices.map {
                choiceSuggestion($0, prefix: "autocomplete", symbol: "sparkle.magnifyingglass")
            }
        }
        if !option.choices.isEmpty {
            return option.choices
                .filter { matches($0.displayName, query: query) }
                .map { choiceSuggestion($0, prefix: "choice", symbol: "checkmark.circle") }
        }
        switch option.type {
        case .boolean:
            return [true, false].map { value in
                let title = value ? "True" : "False"
                return ApplicationCommandSuggestion(
                    id: "boolean:\(value)", title: title,
                    systemImage: value ? "checkmark.circle" : "xmark.circle",
                    action: .value(.boolean(value), displayText: title)
                )
            }.filter { matches($0.title, query: query) }
        case .user:
            return members.compactMap { member in
                guard matches(member.user.displayName, member.user.username, query: query) else {
                    return nil
                }
                return ApplicationCommandSuggestion(
                    id: "user:\(member.user.id)",
                    title: member.user.displayName,
                    trailingText: "@\(member.user.username)",
                    leadingVisual: .user(
                        name: member.user.displayName,
                        avatarURL: member.guildAvatarURL ?? member.user.avatarURL,
                        decorationURL: member.user.avatarDecorationURL,
                        status: member.status
                    ),
                    action: .value(
                        .user(member.user.id),
                        displayText: "@\(member.user.displayName)"
                    )
                )
            }
        case .channel:
            return channels.compactMap { channel in
                guard option.channelTypes.isEmpty
                        || option.channelTypes.contains(channel.discordCommandType),
                      matches(channel.name, channel.category, query: query)
                else { return nil }
                return ApplicationCommandSuggestion(
                    id: "channel:\(channel.id)", title: channel.name,
                    trailingText: channel.category, systemImage: channel.kind == .voice
                        ? "speaker.wave.2" : "number",
                    action: .value(.channel(channel.id), displayText: "#\(channel.name)")
                )
            }
        case .role, .mentionable:
            return roleSuggestions(
                for: option,
                query: query,
                members: members,
                roles: roles
            )
        case .attachment:
            return [
                ApplicationCommandSuggestion(
                    id: "attachment", title: "Choose a file…",
                    trailingText: option.displayName,
                    systemImage: "paperclip", action: .chooseAttachment
                )
            ]
        default:
            return []
        }
    }

    private static func roleSuggestions(
        for option: ApplicationCommandOption,
        query: String,
        members: [Member],
        roles: [GuildRole]
    ) -> [ApplicationCommandSuggestion] {
        var values = roles
            .filter { matches($0.name, query: query) }
            .sorted { $0.position > $1.position }
            .map { role in
                ApplicationCommandSuggestion(
                    id: "role:\(role.id)", title: "@\(role.name)",
                    leadingVisual: .role(
                        colorHex: role.colorHex,
                        iconURL: role.iconURL,
                        unicodeEmoji: role.unicodeEmoji
                    ),
                    action: .value(
                        option.type == .mentionable
                            ? .mentionable(role.id.description) : .role(role.id),
                        displayText: "@\(role.name)"
                    )
                )
            }
        guard option.type == .mentionable else { return values }
        values.insert(
            contentsOf: members.compactMap { member in
                guard matches(
                    member.user.displayName, member.user.username, query: query
                ) else { return nil }
                return ApplicationCommandSuggestion(
                    id: "mentionable-user:\(member.user.id)",
                    title: member.user.displayName,
                    trailingText: "@\(member.user.username)",
                    leadingVisual: .user(
                        name: member.user.displayName,
                        avatarURL: member.guildAvatarURL ?? member.user.avatarURL,
                        decorationURL: member.user.avatarDecorationURL,
                        status: member.status
                    ),
                    action: .value(
                        .mentionable(member.user.id.description),
                        displayText: "@\(member.user.displayName)"
                    )
                )
            },
            at: 0
        )
        return values
    }

    private static func choiceSuggestion(
        _ choice: ApplicationCommandChoice,
        prefix: String,
        symbol: String
    ) -> ApplicationCommandSuggestion {
        ApplicationCommandSuggestion(
            id: "\(prefix):\(choice.id)", title: choice.displayName,
            systemImage: symbol,
            action: .value(argument(for: choice.value), displayText: choice.displayName)
        )
    }

    private static func usefulOptionalFieldDescription(
        _ option: ApplicationCommandOption
    ) -> String? {
        let description = option.displayDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { return nil }
        let genericDescriptions: Set<String> = switch option.type {
        case .string: ["string", "text"]
        case .integer: ["integer"]
        case .number: ["number"]
        case .boolean: ["boolean"]
        case .user: ["user", "member"]
        case .channel: ["channel", "text channel", "voice channel"]
        case .role: ["role"]
        case .mentionable: ["mentionable", "user or role", "member or role"]
        case .attachment: ["attachment", "file"]
        default: []
        }
        return genericDescriptions.contains(description.lowercased()) ? nil : description
    }

    private static func argument(
        for value: ApplicationCommandChoiceValue
    ) -> ApplicationCommandArgument {
        switch value {
        case let .string(value): .string(value)
        case let .integer(value): .integer(value)
        case let .number(value): .number(value)
        }
    }

    private static func matches(_ values: String?..., query: String) -> Bool {
        query.isEmpty || values.compactMap { $0 }.contains {
            $0.localizedCaseInsensitiveContains(query)
        }
    }
}

struct ApplicationCommandSuggestionPanel: View {
    let heading: String
    let suggestions: [ApplicationCommandSuggestion]
    let selectedIndex: Int
    let isLoading: Bool
    let error: String?
    let select: (ApplicationCommandSuggestion) -> Void
    let highlight: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(heading.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 5)
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading suggestions…")
                }
                .foregroundStyle(.secondary)
                .padding(10)
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(suggestions.enumerated(), id: \.element.id) { index, suggestion in
                            ApplicationCommandSuggestionRow(
                                title: suggestion.title,
                                trailingText: suggestion.trailingText,
                                leadingVisual: suggestion.leadingVisual,
                                isSelected: index == selectedIndex,
                                select: { select(suggestion) },
                                highlight: { highlight(index) }
                            )
                        }
                    }
                    .padding(.horizontal, 5)
                    .padding(.bottom, 5)
                }
                .frame(height: min(340, CGFloat(max(1, suggestions.count)) * 42))
            }
        }
        .frame(maxWidth: .infinity)
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
    }
}

private struct ApplicationCommandSuggestionRow: View {
    let title: String
    let trailingText: String?
    let leadingVisual: ApplicationCommandSuggestion.LeadingVisual
    let isSelected: Bool
    let select: () -> Void
    let highlight: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 9) {
                ApplicationCommandSuggestionIcon(visual: leadingVisual)
                    .frame(width: 28, height: 28)
                Text(title)
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 10)
                if let trailingText, !trailingText.isEmpty {
                    Text(trailingText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 260, alignment: .trailing)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 40)
            .contentShape(Rectangle())
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
        .clipShape(
            ConcentricRectangle(
                cornerRadius: 7,
                style: .continuous
            )
        )
        .onHover { hovering in
            guard hovering else { return }
            highlight()
        }
    }

    private var titleColor: Color {
        guard case let .role(colorHex, _, _) = leadingVisual,
              let colorHex,
              colorHex != 0
        else { return .primary }
        return Color(hex: colorHex)
    }
}

private struct ApplicationCommandSuggestionIcon: View {
    let visual: ApplicationCommandSuggestion.LeadingVisual

    var body: some View {
        switch visual {
        case let .symbol(name):
            Image(systemName: name)
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
        case let .user(name, avatarURL, decorationURL, status):
            ZStack(alignment: .bottomTrailing) {
                DecoratedAvatarView(
                    name: name,
                    avatarURL: avatarURL,
                    decorationURL: decorationURL,
                    size: 25
                )
                PresenceIndicator(status: status, size: 8)
                    .overlay(Circle().stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 1.5))
            }
        case let .role(colorHex, iconURL, unicodeEmoji):
            if let iconURL {
                AnimatedRemoteImage(url: iconURL)
                    .frame(width: 22, height: 22)
            } else if let unicodeEmoji, !unicodeEmoji.isEmpty {
                Text(unicodeEmoji)
                    .font(.system(size: 18))
            } else {
                Circle()
                    .fill(colorHex.map(Color.init(hex:)) ?? .secondary)
                    .frame(width: 13, height: 13)
            }
        }
    }
}

extension NSAttributedString.Key {
    nonisolated static let applicationCommandOptionID = NSAttributedString.Key(
        "dev.sakuracord.application-command-option-id"
    )
    nonisolated static let applicationCommandFieldPart = NSAttributedString.Key(
        "dev.sakuracord.application-command-field-part"
    )
    nonisolated static let applicationCommandPlaceholder = NSAttributedString.Key(
        "dev.sakuracord.application-command-placeholder"
    )
    nonisolated static let applicationCommandAtomicValue = NSAttributedString.Key(
        "dev.sakuracord.application-command-atomic-value"
    )
    nonisolated static let applicationCommandSerializedText = NSAttributedString.Key(
        "dev.sakuracord.application-command-serialized-text"
    )
}

struct ApplicationCommandInlineInput: View {
    let composer: ApplicationCommandComposerModel
    let roles: [GuildRole]
    let sendWithReturn: Bool
    let onTextChange: (ApplicationCommandOption, String) -> Void
    let onSubmit: () -> Void
    let onKeyboardCommand: (ComposerAutocompleteCommand) -> Bool
    let cancel: () -> Void
    @Binding var isFocused: Bool

    var body: some View {
        let displayedOptions = composer.displayedOptions
        HStack(spacing: 7) {
            if let command = composer.activeCommand {
                CommandApplicationIcon(application: command.application, size: 24)
                ApplicationCommandStructuredTextView(
                    document: ApplicationCommandTextDocument.make(
                        command: command,
                        options: displayedOptions,
                        values: Dictionary(uniqueKeysWithValues: displayedOptions.map {
                            ($0.id, composer.value(for: $0))
                        }),
                        drafts: Dictionary(uniqueKeysWithValues: displayedOptions.map {
                            ($0.id, composer.draftText(for: $0))
                        }),
                        roles: roles,
                        focusedOptionID: composer.focusedOptionID
                    ),
                    focusedOptionID: composer.focusedOptionID,
                    sendWithReturn: sendWithReturn,
                    onTextChange: onTextChange,
                    onFocusOption: { optionID in
                        guard let optionID,
                              let option = displayedOptions.first(where: { $0.id == optionID })
                        else {
                            composer.leaveOptionFocus()
                            return
                        }
                        composer.focus(option)
                    },
                    focusedOptionIDProvider: { composer.focusedOptionID },
                    onSubmit: onSubmit,
                    onKeyboardCommand: onKeyboardCommand,
                    isFocused: $isFocused
                )
                .frame(height: 34)
                .layoutPriority(1)

                Button(action: cancel) {
                    Image(systemName: "xmark")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Cancel command")
            }
        }
    }
}

struct ApplicationCommandTextDocument {
    struct Segment {
        let option: ApplicationCommandOption
        let labelRange: NSRange
        let valueRange: NSRange
        let fieldRange: NSRange
        let editableText: String
        let isPlaceholder: Bool
    }

    let attributedText: NSAttributedString
    let segments: [Segment]
    let focusedOptionID: String?

    static func make(
        command: ApplicationCommand,
        options: [ApplicationCommandOption],
        values: [String: ApplicationCommandArgument?],
        drafts: [String: String],
        roles: [GuildRole],
        focusedOptionID: String?
    ) -> ApplicationCommandTextDocument {
        let font = NSFont.systemFont(ofSize: 15)
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(
            string: "/\(command.displayName)",
            attributes: baseAttributes(font: font, weight: .semibold, color: .labelColor)
        ))
        var segments: [Segment] = []
        for option in options {
            var separatorAttributes = baseAttributes(
                font: font,
                weight: .regular,
                color: .labelColor
            )
            separatorAttributes[.applicationCommandSerializedText] = " "
            result.append(NSAttributedString(string: "   ", attributes: separatorAttributes))
            let fieldStart = result.length
            let labelStart = result.length
            let label = "\(option.displayName) "
            var labelAttributes = baseAttributes(
                font: font, weight: .semibold, color: .labelColor
            )
            labelAttributes[.applicationCommandOptionID] = option.id
            labelAttributes[.applicationCommandFieldPart] = "label"
            labelAttributes[.applicationCommandSerializedText] = "\(option.displayName): "
            result.append(NSAttributedString(string: label, attributes: labelAttributes))
            let labelRange = NSRange(location: labelStart, length: (label as NSString).length)

            let draft = drafts[option.id] ?? ""
            let placeholder = draft.isEmpty
            let renderedValue = placeholder ? (option.isRequired ? "Required" : "Optional") : draft
            let value = values[option.id] ?? nil
            var valueAttributes = baseAttributes(
                font: font,
                weight: valueWeight(value: value, placeholder: placeholder),
                color: valueColor(
                    value: value,
                    roles: roles,
                    placeholder: placeholder
                )
            )
            valueAttributes[.applicationCommandOptionID] = option.id
            valueAttributes[.applicationCommandFieldPart] = "value"
            if placeholder {
                valueAttributes[.applicationCommandPlaceholder] = true
            }
            let valueStart = result.length
            let collapsesToAtomicValue = !placeholder && option.id != focusedOptionID
            if collapsesToAtomicValue {
                result.append(
                    atomicValue(
                        renderedValue,
                        attributes: valueAttributes,
                        optionID: option.id,
                        font: font
                    )
                )
            } else {
                result.append(NSAttributedString(string: renderedValue, attributes: valueAttributes))
            }
            let valueRange = NSRange(
                location: valueStart,
                length: collapsesToAtomicValue ? 1 : (renderedValue as NSString).length
            )
            segments.append(Segment(
                option: option,
                labelRange: labelRange,
                valueRange: valueRange,
                fieldRange: NSRange(location: fieldStart, length: result.length - fieldStart),
                editableText: draft,
                isPlaceholder: placeholder
            ))
        }
        return ApplicationCommandTextDocument(
            attributedText: result,
            segments: segments,
            focusedOptionID: focusedOptionID
        )
    }

    func segment(optionID: String) -> Segment? {
        segments.first { $0.option.id == optionID }
    }

    func valueSegment(at location: Int) -> Segment? {
        segments.first { segment in
            location >= segment.valueRange.location && location <= NSMaxRange(segment.valueRange)
        }
    }

    func segmentsIntersectingValues(_ range: NSRange) -> [Segment] {
        segments.filter { segment in
            if range.length == 0 {
                return range.location >= segment.valueRange.location
                    && range.location <= NSMaxRange(segment.valueRange)
            }
            return NSIntersectionRange(range, segment.valueRange).length > 0
        }
    }

    private static func baseAttributes(
        font: NSFont,
        weight: NSFont.Weight,
        color: NSColor
    ) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        paragraph.maximumLineHeight = 20
        paragraph.minimumLineHeight = 20
        return [
            .font: NSFont.systemFont(ofSize: font.pointSize, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
    }

    private static func valueColor(
        value: ApplicationCommandArgument?,
        roles: [GuildRole],
        placeholder: Bool
    ) -> NSColor {
        guard !placeholder else { return .tertiaryLabelColor }
        switch value {
        case .user, .channel:
            return .controlAccentColor
        case let .mentionable(id):
            guard let roleID = RoleID(id),
                  roles.contains(where: { $0.id == roleID })
            else { return .controlAccentColor }
        default:
            break
        }
        let roleID: RoleID? = switch value {
        case let .role(id): id
        case let .mentionable(id): RoleID(id)
        default: nil
        }
        guard let roleID,
              let color = roles.first(where: { $0.id == roleID })?.colorHex,
              color != 0
        else { return .labelColor }
        return NSColor(
            srgbRed: CGFloat((color >> 16) & 0xFF) / 255,
            green: CGFloat((color >> 8) & 0xFF) / 255,
            blue: CGFloat(color & 0xFF) / 255,
            alpha: 1
        )
    }

    private static func valueWeight(
        value: ApplicationCommandArgument?,
        placeholder: Bool
    ) -> NSFont.Weight {
        guard !placeholder else { return .regular }
        return switch value {
        case .user, .channel, .role, .mentionable: .semibold
        default: .regular
        }
    }

    private static func atomicValue(
        _ text: String,
        attributes: [NSAttributedString.Key: Any],
        optionID: String,
        font: NSFont
    ) -> NSAttributedString {
        let rendered = NSAttributedString(string: text, attributes: attributes)
        let measured = rendered.size()
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let imageSize = NSSize(width: ceil(measured.width), height: ceil(lineHeight))
        let image = NSImage(size: imageSize, flipped: false) { bounds in
            rendered.draw(
                at: NSPoint(
                    x: bounds.minX,
                    y: bounds.midY - measured.height / 2
                )
            )
            return true
        }
        image.accessibilityDescription = text

        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(
            x: 0,
            y: (font.ascender + font.descender - imageSize.height) / 2,
            width: imageSize.width,
            height: imageSize.height
        )
        let value = NSMutableAttributedString(attachment: attachment)
        var attachmentAttributes = attributes
        attachmentAttributes[.applicationCommandOptionID] = optionID
        attachmentAttributes[.applicationCommandFieldPart] = "value"
        attachmentAttributes[.applicationCommandAtomicValue] = true
        attachmentAttributes[.applicationCommandSerializedText] = text
        value.addAttributes(
            attachmentAttributes,
            range: NSRange(location: 0, length: value.length)
        )
        return value
    }
}

enum ApplicationCommandEditorTextMap {
    static func optionID(atCaret location: Int, in text: NSAttributedString) -> String? {
        guard text.length > 0 else { return nil }
        let current = min(max(0, location), text.length - 1)
        let candidates = current > 0 ? [current, current - 1] : [current]
        for candidate in candidates {
            let attributes = text.attributes(at: candidate, effectiveRange: nil)
            guard attributes[.applicationCommandFieldPart] as? String == "value",
                  let optionID = attributes[.applicationCommandOptionID] as? String
            else { continue }
            return optionID
        }
        return nil
    }

    static func optionID(atCharacter location: Int, in text: NSAttributedString) -> String? {
        guard location >= 0, location < text.length else { return nil }
        return text.attribute(
            .applicationCommandOptionID,
            at: location,
            effectiveRange: nil
        ) as? String
    }

    static func fieldPart(atCharacter location: Int, in text: NSAttributedString) -> String? {
        guard location >= 0, location < text.length else { return nil }
        return text.attribute(
            .applicationCommandFieldPart,
            at: location,
            effectiveRange: nil
        ) as? String
    }

    static func range(
        optionID: String,
        part: String,
        in text: NSAttributedString
    ) -> NSRange? {
        var result: NSRange?
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            guard attributes[.applicationCommandOptionID] as? String == optionID,
                  attributes[.applicationCommandFieldPart] as? String == part
            else { return }
            result = result.map { NSUnionRange($0, range) } ?? range
        }
        return result
    }

    static func isPlaceholder(optionID: String, in text: NSAttributedString) -> Bool {
        guard let range = range(optionID: optionID, part: "value", in: text),
              range.length > 0
        else { return false }
        return text.attribute(
            .applicationCommandPlaceholder,
            at: range.location,
            effectiveRange: nil
        ) as? Bool == true
    }

    static func editableText(optionID: String, in text: NSAttributedString) -> String {
        guard !isPlaceholder(optionID: optionID, in: text),
              let range = range(optionID: optionID, part: "value", in: text)
        else { return "" }
        if let serialized = text.attribute(
            .applicationCommandSerializedText,
            at: range.location,
            effectiveRange: nil
        ) as? String {
            return serialized
        }
        return text.attributedSubstring(from: range).string
    }

    static func isAtomicValue(optionID: String, in text: NSAttributedString) -> Bool {
        guard let range = range(optionID: optionID, part: "value", in: text),
              range.length > 0
        else { return false }
        return text.attribute(
            .applicationCommandAtomicValue,
            at: range.location,
            effectiveRange: nil
        ) as? Bool == true
    }
}

enum ApplicationCommandClipboardSerializer {
    nonisolated static func string(
        from value: NSAttributedString,
        range: NSRange
    ) -> String {
        var output = ""
        value.enumerateAttributes(in: range) { attributes, effectiveRange, _ in
            if let serialized = attributes[.applicationCommandSerializedText] as? String {
                output += serialized
            } else {
                output += value.attributedSubstring(from: effectiveRange).string
            }
        }
        return output
    }
}

private struct ApplicationCommandStructuredTextView: NSViewRepresentable {
    let document: ApplicationCommandTextDocument
    let focusedOptionID: String?
    let sendWithReturn: Bool
    let onTextChange: (ApplicationCommandOption, String) -> Void
    let onFocusOption: (String?) -> Void
    let focusedOptionIDProvider: () -> String?
    let onSubmit: () -> Void
    let onKeyboardCommand: (ComposerAutocompleteCommand) -> Bool
    @Binding var isFocused: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(
            containerSize: NSSize(width: CGFloat.greatestFiniteMagnitude, height: 34)
        )
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = true
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = 1
        layoutManager.addTextContainer(textContainer)

        let textView = ApplicationCommandNSTextView(frame: .zero, textContainer: textContainer)
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = false
        textView.textContainerInset = NSSize(width: 6, height: 7)
        textView.minSize = NSSize(width: 0, height: 34)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: 34)
        textView.allowsUndo = true
        textView.onKeyboardCommand = onKeyboardCommand
        textView.focusedOptionIDProvider = focusedOptionIDProvider
        textView.onSubmit = onSubmit
        textView.sendWithReturn = sendWithReturn
        textView.document = document
        textView.setAccessibilityLabel("Command input")

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .automatic
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ApplicationCommandNSTextView else { return }
        context.coordinator.parent = self
        textView.onKeyboardCommand = onKeyboardCommand
        textView.focusedOptionIDProvider = focusedOptionIDProvider
        textView.onSubmit = onSubmit
        textView.sendWithReturn = sendWithReturn
        context.coordinator.apply(document: document, to: textView, viewportWidth: scrollView.bounds.width)
        context.coordinator.applyFocus(to: textView)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView _: NSScrollView,
        context _: Context
    ) -> CGSize? {
        CGSize(width: proposal.width ?? 240, height: 34)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ApplicationCommandStructuredTextView
        private var isApplyingDocument = false
        private var appliedFocus = false
        private var lastFocusedOptionID: String?
        private var pendingCaret: (optionID: String, offset: Int)?
        private var pendingEditOptionID: String?

        init(parent: ApplicationCommandStructuredTextView) {
            self.parent = parent
        }

        func apply(
            document: ApplicationCommandTextDocument,
            to textView: ApplicationCommandNSTextView,
            viewportWidth: CGFloat
        ) {
            let selectedRange = textView.selectedRange()
            let focusedChanged = lastFocusedOptionID != parent.focusedOptionID
            let expandsAtomicValue = parent.focusedOptionID.map {
                ApplicationCommandEditorTextMap.isAtomicValue(
                    optionID: $0,
                    in: textView.attributedString()
                )
            } ?? false
            isApplyingDocument = true
            textView.document = document
            if !textView.attributedString().isEqual(to: document.attributedText) {
                textView.textStorage?.setAttributedString(document.attributedText)
            }
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            let usedWidth = textView.layoutManager?.usedRect(for: textView.textContainer!).width ?? 0
            textView.frame.size = NSSize(width: max(viewportWidth, usedWidth + 20), height: 34)

            if let pendingCaret,
               let segment = document.segment(optionID: pendingCaret.optionID)
            {
                let displayOffset = segment.isPlaceholder
                    ? 0 : min(pendingCaret.offset, segment.valueRange.length)
                textView.setSelectedRange(NSRange(
                    location: segment.valueRange.location + displayOffset,
                    length: 0
                ))
                self.pendingCaret = nil
            } else if focusedChanged,
                      let optionID = parent.focusedOptionID,
                      let segment = document.segment(optionID: optionID),
                      ApplicationCommandEditorTextMap.optionID(
                          atCaret: selectedRange.location,
                          in: textView.attributedString()
                      ) != optionID
            {
                textView.setSelectedRange(
                    expandsAtomicValue && !segment.isPlaceholder
                        ? segment.valueRange
                        : NSRange(
                            location: segment.valueRange.location
                                + (segment.isPlaceholder ? 0 : segment.valueRange.length),
                            length: 0
                        )
                )
            } else {
                textView.setSelectedRange(clampedSelection(
                    selectedRange,
                    documentLength: document.attributedText.length
                ))
            }
            lastFocusedOptionID = parent.focusedOptionID
            textView.scrollRangeToVisible(textView.selectedRange())
            pendingEditOptionID = nil
            isApplyingDocument = false
            textView.needsDisplay = true
        }

        private func clampedSelection(_ range: NSRange, documentLength: Int) -> NSRange {
            guard range.location != NSNotFound else {
                return NSRange(location: documentLength, length: 0)
            }
            let location = min(max(0, range.location), documentLength)
            let length = min(max(0, range.length), documentLength - location)
            return NSRange(location: location, length: length)
        }

        func applyFocus(to textView: NSTextView) {
            guard parent.isFocused != appliedFocus else { return }
            appliedFocus = parent.isFocused
            if parent.isFocused {
                Task { @MainActor [weak textView] in
                    guard let textView, self.parent.isFocused else { return }
                    textView.window?.makeFirstResponder(textView)
                }
            } else if textView.window?.firstResponder === textView {
                textView.window?.makeFirstResponder(nil)
            }
        }

        func textDidBeginEditing(_: Notification) {
            appliedFocus = true
            if !parent.isFocused { parent.isFocused = true }
        }

        func textDidEndEditing(_: Notification) {
            appliedFocus = false
            if parent.isFocused { parent.isFocused = false }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplyingDocument,
                  let textView = notification.object as? NSTextView
            else { return }
            let range = textView.selectedRange()
            let optionID = pendingEditOptionID ?? selectionOptionID(
                for: range,
                in: textView.attributedString()
            )
            if optionID != parent.focusedOptionID {
                parent.onFocusOption(optionID)
            }
            if let commandTextView = textView as? ApplicationCommandNSTextView {
                commandTextView.updateTypingAttributes(at: range.location)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingDocument,
                  let textView = notification.object as? NSTextView
            else { return }
            let range = textView.selectedRange()
            if let optionID = ApplicationCommandEditorTextMap.optionID(
                atCaret: range.location,
                in: textView.attributedString()
            ),
               let segment = parent.document.segment(optionID: optionID)
            {
                pendingEditOptionID = optionID
                pendingCaret = (
                    optionID,
                    editableOffset(at: range.location, optionID: optionID, in: textView.attributedString())
                )
                let value = ApplicationCommandEditorTextMap.editableText(
                    optionID: optionID,
                    in: textView.attributedString()
                )
                if value != segment.editableText {
                    parent.onTextChange(segment.option, value)
                }
            }
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            guard !isApplyingDocument else { return true }
            let replacement = replacementString ?? ""
            let liveSegments = liveSegments(in: textView.attributedString())
            let touched = liveSegmentsIntersectingValues(
                affectedCharRange,
                segments: liveSegments,
                text: textView.attributedString()
            )
            if touched.count == 1,
               let live = touched.first,
               live.isAtomic
            {
                pendingEditOptionID = live.segment.option.id
                pendingCaret = (
                    live.segment.option.id,
                    replacement.isEmpty ? 0 : (replacement as NSString).length
                )
                if parent.focusedOptionID != live.segment.option.id {
                    parent.onFocusOption(live.segment.option.id)
                }
                parent.onTextChange(live.segment.option, replacement)
                return false
            }
            if touched.count == 1,
               let live = touched.first,
               !live.isPlaceholder,
               affectedCharRange.location >= live.valueRange.location,
               NSMaxRange(affectedCharRange) <= NSMaxRange(live.valueRange)
            {
                pendingEditOptionID = live.segment.option.id
                textView.typingAttributes = valueAttributes(for: live, in: textView)
                return true
            }

            let targets = touched.isEmpty
                ? nearestEditableSegments(
                    to: affectedCharRange,
                    replacement: replacement,
                    segments: liveSegments
                )
                : touched
            guard !targets.isEmpty else { return false }
            let first = targets[0]
            pendingEditOptionID = first.segment.option.id
            var caretOffset = first.editableText.utf16.count
            var updates: [(LiveSegment, String)] = []
            for (index, live) in targets.enumerated() {
                let localRange = localEditableRange(
                    affectedCharRange,
                    in: live,
                    replacement: replacement
                )
                let source = live.editableText as NSString
                let safeRange = NSIntersectionRange(
                    localRange,
                    NSRange(location: 0, length: source.length)
                )
                let inserted = index == 0 ? replacement : ""
                let updated = source.replacingCharacters(in: safeRange, with: inserted)
                if index == 0 { caretOffset = safeRange.location + (inserted as NSString).length }
                if updated != live.editableText {
                    updates.append((live, updated))
                } else if replacement.isEmpty,
                          live.isPlaceholder,
                          !live.segment.option.isRequired,
                          parent.focusedOptionID == live.segment.option.id
                {
                    _ = parent.onKeyboardCommand(.removeField)
                }
            }
            pendingCaret = (first.segment.option.id, caretOffset)
            if let immediateValue = updates.first(where: {
                $0.0.segment.option.id == first.segment.option.id
            })?.1,
               let commandTextView = textView as? ApplicationCommandNSTextView
            {
                applyImmediateValue(
                    immediateValue,
                    to: commandTextView,
                    segment: first,
                    caretOffset: caretOffset
                )
            }
            if parent.focusedOptionID != first.segment.option.id {
                parent.onFocusOption(first.segment.option.id)
            }
            for (live, updated) in updates {
                parent.onTextChange(live.segment.option, updated)
            }
            return false
        }

        private func applyImmediateValue(
            _ value: String,
            to textView: ApplicationCommandNSTextView,
            segment: LiveSegment,
            caretOffset: Int
        ) {
            var attributes = valueAttributes(for: segment, in: textView)
            let renderedValue: String
            if value.isEmpty {
                renderedValue = segment.segment.option.isRequired ? "Required" : "Optional"
                attributes[.applicationCommandPlaceholder] = true
                attributes[.foregroundColor] = NSColor.tertiaryLabelColor
            } else {
                renderedValue = value
                attributes[.applicationCommandPlaceholder] = nil
                attributes[.foregroundColor] = NSColor.labelColor
            }
            isApplyingDocument = true
            textView.textStorage?.replaceCharacters(
                in: segment.valueRange,
                with: NSAttributedString(string: renderedValue, attributes: attributes)
            )
            textView.setSelectedRange(NSRange(
                location: segment.valueRange.location + min(caretOffset, renderedValue.utf16.count),
                length: 0
            ))
            textView.typingAttributes = attributes
            isApplyingDocument = false
        }

        private struct LiveSegment {
            let segment: ApplicationCommandTextDocument.Segment
            let valueRange: NSRange
            let editableText: String
            let isPlaceholder: Bool
            let isAtomic: Bool
        }

        private func liveSegments(in text: NSAttributedString) -> [LiveSegment] {
            parent.document.segments.compactMap { segment in
                guard let valueRange = ApplicationCommandEditorTextMap.range(
                    optionID: segment.option.id,
                    part: "value",
                    in: text
                ) else { return nil }
                return LiveSegment(
                    segment: segment,
                    valueRange: valueRange,
                    editableText: ApplicationCommandEditorTextMap.editableText(
                        optionID: segment.option.id,
                        in: text
                    ),
                    isPlaceholder: ApplicationCommandEditorTextMap.isPlaceholder(
                        optionID: segment.option.id,
                        in: text
                    ),
                    isAtomic: ApplicationCommandEditorTextMap.isAtomicValue(
                        optionID: segment.option.id,
                        in: text
                    )
                )
            }
        }

        private func liveSegmentsIntersectingValues(
            _ range: NSRange,
            segments: [LiveSegment],
            text: NSAttributedString
        ) -> [LiveSegment] {
            if range.length == 0,
               let optionID = ApplicationCommandEditorTextMap.optionID(
                   atCaret: range.location,
                   in: text
               )
            {
                return segments.filter { $0.segment.option.id == optionID }
            }
            return segments.filter { NSIntersectionRange(range, $0.valueRange).length > 0 }
        }

        private func nearestEditableSegments(
            to range: NSRange,
            replacement: String,
            segments: [LiveSegment]
        ) -> [LiveSegment] {
            if replacement.isEmpty,
               let previous = segments.last(where: {
                   NSMaxRange($0.valueRange) <= range.location
               })
            {
                return [previous]
            }
            if let next = segments.first(where: {
                $0.valueRange.location >= range.location
            }) {
                return [next]
            }
            return segments.last.map { [$0] } ?? []
        }

        private func localEditableRange(
            _ range: NSRange,
            in segment: LiveSegment,
            replacement: String
        ) -> NSRange {
            guard !segment.isPlaceholder else { return NSRange(location: 0, length: 0) }
            let intersection = NSIntersectionRange(range, segment.valueRange)
            if intersection.length > 0 {
                return NSRange(
                    location: intersection.location - segment.valueRange.location,
                    length: intersection.length
                )
            }
            if replacement.isEmpty, range.location >= NSMaxRange(segment.valueRange) {
                let length = segment.editableText.utf16.count
                return NSRange(location: max(0, length - 1), length: min(1, length))
            }
            return NSRange(
                location: min(
                    max(0, range.location - segment.valueRange.location),
                    segment.editableText.utf16.count
                ),
                length: 0
            )
        }

        private func editableOffset(
            at location: Int,
            optionID: String,
            in value: NSAttributedString
        ) -> Int {
            guard location > 0 else { return 0 }
            let prefix = value.attributedSubstring(from: NSRange(
                location: 0,
                length: min(location, value.length)
            ))
            return ApplicationCommandEditorTextMap.editableText(
                optionID: optionID,
                in: prefix
            ).utf16.count
        }

        private func valueAttributes(
            for segment: LiveSegment,
            in textView: NSTextView
        ) -> [NSAttributedString.Key: Any] {
            var attributes = textView.attributedString().attributes(
                at: min(segment.valueRange.location, max(0, textView.string.utf16.count - 1)),
                effectiveRange: nil
            )
            attributes[.applicationCommandPlaceholder] = nil
            return attributes
        }

        private func selectionOptionID(
            for range: NSRange,
            in text: NSAttributedString
        ) -> String? {
            if range.length == 0 {
                return ApplicationCommandEditorTextMap.optionID(
                    atCaret: range.location,
                    in: text
                )
            }
            let ids = liveSegments(in: text).filter {
                NSIntersectionRange(range, $0.valueRange).length > 0
            }.map(\.segment.option.id)
            return Set(ids).count == 1 ? ids.first : nil
        }
    }
}

final class ApplicationCommandNSTextView: NSTextView {
    var commandPasteboard = NSPasteboard.general

    var document = ApplicationCommandTextDocument(
        attributedText: NSAttributedString(), segments: [], focusedOptionID: nil
    )
    var onKeyboardCommand: (ComposerAutocompleteCommand) -> Bool = { _ in false }
    var focusedOptionIDProvider: () -> String? = { nil }
    var onSubmit: () -> Void = {}
    var sendWithReturn = true
    private lazy var unfocusedTypingMonitor = ComposerUnfocusedTypingMonitor()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        unfocusedTypingMonitor.synchronize(
            with: self,
            enabled: true,
            onUnfocusedReturn: { [weak self] event in
                self?.handleReturn(event) ?? false
            }
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawSelectionOverAttachments(in: dirtyRect)
    }

    override func copy(_ sender: Any?) {
        let range = selectedRange()
        guard range.length > 0 else { return }
        let plainText = ApplicationCommandClipboardSerializer.string(
            from: attributedString(),
            range: range
        )
        commandPasteboard.clearContents()
        commandPasteboard.setString(plainText, forType: .string)
    }

    override func paste(_ sender: Any?) {
        guard let value = commandPasteboard.string(forType: .string) else {
            super.paste(sender)
            return
        }
        insertText(value, replacementRange: selectedRange())
    }

    override func keyDown(with event: NSEvent) {
        let navigationModifiers: NSEvent.ModifierFlags = [.shift, .command, .option, .control]
        let plainNavigation = event.modifierFlags.isDisjoint(with: navigationModifiers)
        if plainNavigation, event.keyCode == 124, movePastProtectedLabelIfNeeded() {
            return
        }
        if plainNavigation, event.keyCode == 123, shouldLeaveCurrentValue(backward: true) {
            moveBetweenValues(.previousField, outsideLocation: commandOutsideLocation)
            return
        }
        if plainNavigation, event.keyCode == 124, shouldLeaveCurrentValue(backward: false) {
            moveBetweenValues(.nextField, outsideLocation: attributedString().length)
            return
        }
        let command: ComposerAutocompleteCommand? = switch event.keyCode {
        case 126 where plainNavigation: .previous
        case 125 where plainNavigation: .next
        case 48 where event.modifierFlags.isDisjoint(with: [.command, .option, .control]):
            event.modifierFlags.contains(.shift) ? .previousField : .advance
        case 36, 76: .accept
        case 53: .dismiss
        case 51 where currentValueIsPlaceholder: .removeField
        case 117 where currentValueIsPlaceholder: .removeField
        default: nil
        }
        if let command, onKeyboardCommand(command) {
            switch command {
            case .advance, .previousField, .nextField:
                moveCaretToFocusedValue(fallback: attributedString().length)
            default:
                break
            }
            return
        }
        if ComposerUnfocusedTypingMonitor.shouldOfferReturn(event.keyCode),
           handleReturn(event)
        {
            return
        }
        super.keyDown(with: event)
    }

    private func handleReturn(_ event: NSEvent) -> Bool {
        let action = ComposerReturnAction.decide(
            sendWithReturn: sendWithReturn,
            shift: event.modifierFlags.contains(.shift),
            command: event.modifierFlags.contains(.command),
            hasMarkedText: hasMarkedText()
        )
        guard action == .send else { return false }
        onSubmit()
        return true
    }

    func updateTypingAttributes(at location: Int) {
        let text = attributedString()
        guard let optionID = ApplicationCommandEditorTextMap.optionID(
            atCaret: location,
            in: text
        ),
              let valueRange = ApplicationCommandEditorTextMap.range(
                  optionID: optionID,
                  part: "value",
                  in: text
              ),
              text.length > 0
        else {
            return
        }
        var attributes = text.attributes(
            at: min(valueRange.location, text.length - 1),
            effectiveRange: nil
        )
        attributes[.applicationCommandPlaceholder] = nil
        typingAttributes = attributes
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager, let textContainer else { return }
        let origin = textContainerOrigin
        for segment in document.segments {
            guard let labelRange = ApplicationCommandEditorTextMap.range(
                optionID: segment.option.id,
                part: "label",
                in: attributedString()
            ),
                  let valueRange = ApplicationCommandEditorTextMap.range(
                      optionID: segment.option.id,
                      part: "value",
                      in: attributedString()
                  )
            else { continue }
            let fieldRange = NSUnionRange(labelRange, valueRange)
            let fieldGlyphs = layoutManager.glyphRange(
                forCharacterRange: fieldRange,
                actualCharacterRange: nil
            )
            var fieldRect = layoutManager.boundingRect(
                forGlyphRange: fieldGlyphs,
                in: textContainer
            )
            fieldRect.origin.x += origin.x - 4
            fieldRect.origin.y = 3
            fieldRect.size.width += 8
            fieldRect.size.height = 28
            guard fieldRect.intersects(rect) else { continue }

            let path = NSBezierPath(
                concentricRoundedRect: fieldRect,
                cornerRadius: 7
            )
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            path.fill()

            let labelGlyphs = layoutManager.glyphRange(
                forCharacterRange: labelRange,
                actualCharacterRange: nil
            )
            var labelRect = layoutManager.boundingRect(
                forGlyphRange: labelGlyphs,
                in: textContainer
            )
            labelRect.origin.x = fieldRect.minX
            labelRect.origin.y = fieldRect.minY
            labelRect.size.width += 7
            labelRect.size.height = fieldRect.height
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            NSColor.controlBackgroundColor.withAlphaComponent(0.54).setFill()
            labelRect.fill()
            NSGraphicsContext.restoreGraphicsState()

            let isFocused = segment.option.id == document.focusedOptionID
            (isFocused ? NSColor.keyboardFocusIndicatorColor.withAlphaComponent(0.72)
                : NSColor.labelColor.withAlphaComponent(0.18)).setStroke()
            path.lineWidth = isFocused ? 1.5 : 1
            path.stroke()
        }
    }

    private var currentSegment: ApplicationCommandTextDocument.Segment? {
        guard let optionID = ApplicationCommandEditorTextMap.optionID(
            atCaret: selectedRange().location,
            in: attributedString()
        ) else { return nil }
        return document.segment(optionID: optionID)
    }

    private var currentValueIsPlaceholder: Bool {
        guard let optionID = currentSegment?.option.id else { return false }
        return ApplicationCommandEditorTextMap.isPlaceholder(
            optionID: optionID,
            in: attributedString()
        )
    }

    private var commandOutsideLocation: Int {
        guard let firstID = document.segments.first?.option.id,
              let labelRange = ApplicationCommandEditorTextMap.range(
                  optionID: firstID,
                  part: "label",
                  in: attributedString()
              )
        else { return attributedString().length }
        return max(0, labelRange.location - 1)
    }

    override func mouseDown(with event: NSEvent) {
        let text = attributedString()
        guard let location = characterLocation(for: event),
              let optionID = ApplicationCommandEditorTextMap.optionID(
                  atCharacter: location,
                  in: text
              ),
              let part = ApplicationCommandEditorTextMap.fieldPart(
                  atCharacter: location,
                  in: text
              ),
              part == "label"
                  || ApplicationCommandEditorTextMap.isPlaceholder(optionID: optionID, in: text)
                  || ApplicationCommandEditorTextMap.isAtomicValue(optionID: optionID, in: text),
              let valueRange = ApplicationCommandEditorTextMap.range(
                  optionID: optionID,
                  part: "value",
                  in: text
              )
        else {
            super.mouseDown(with: event)
            return
        }

        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: valueRange.location, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    private func characterLocation(for event: NSEvent) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        let viewPoint = convert(event.locationInWindow, from: nil)
        let origin = textContainerOrigin
        let containerPoint = NSPoint(x: viewPoint.x - origin.x, y: viewPoint.y - origin.y)
        var fraction: CGFloat = 0
        let location = layoutManager.characterIndex(
            for: containerPoint,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: &fraction
        )
        return min(location, max(0, attributedString().length - 1))
    }

    private func shouldLeaveCurrentValue(backward: Bool) -> Bool {
        guard selectedRange().length == 0,
              let optionID = currentSegment?.option.id,
              let valueRange = ApplicationCommandEditorTextMap.range(
                  optionID: optionID,
                  part: "value",
                  in: attributedString()
              )
        else { return false }
        if currentValueIsPlaceholder { return true }
        return backward
            ? selectedRange().location <= valueRange.location
            : selectedRange().location >= NSMaxRange(valueRange)
    }

    private func moveBetweenValues(
        _ command: ComposerAutocompleteCommand,
        outsideLocation: Int
    ) {
        guard onKeyboardCommand(command) else { return }
        moveCaretToFocusedValue(fallback: outsideLocation)
    }

    private func moveCaretToFocusedValue(fallback: Int) {
        guard let optionID = focusedOptionIDProvider(),
              let valueRange = ApplicationCommandEditorTextMap.range(
                  optionID: optionID,
                  part: "value",
                  in: attributedString()
              )
        else {
            setSelectedRange(NSRange(
                location: min(fallback, attributedString().length),
                length: 0
            ))
            return
        }
        let location = ApplicationCommandEditorTextMap.isPlaceholder(
            optionID: optionID,
            in: attributedString()
        ) ? valueRange.location : NSMaxRange(valueRange)
        setSelectedRange(NSRange(location: location, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    private func movePastProtectedLabelIfNeeded() -> Bool {
        guard selectedRange().length == 0 else { return false }
        let location = selectedRange().location
        let text = attributedString()
        guard location < text.length,
              ApplicationCommandEditorTextMap.fieldPart(
                  atCharacter: location,
                  in: text
              ) == "label",
              let optionID = ApplicationCommandEditorTextMap.optionID(
                  atCharacter: location,
                  in: text
              ),
              let valueRange = ApplicationCommandEditorTextMap.range(
                  optionID: optionID,
                  part: "value",
                  in: text
              )
        else { return false }
        setSelectedRange(NSRange(location: valueRange.location, length: 0))
        scrollRangeToVisible(selectedRange())
        return true
    }
}
