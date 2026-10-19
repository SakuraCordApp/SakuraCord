import MessageRendering
import SakuraCordModels
import SwiftUI

struct ProfilePersonalWidgetCard: View {
    let id: String
    let widget: ProfilePersonalWidget
    let animates: Bool
    var editor: ProfileEditorState?
    @State private var expanded = false
    @State private var isExpansionHovered = false
    @State private var hasClippedText = false
    @State private var imageVisibilityOverrides: [ProfileWidgetField.ID: Bool] = [:]

    private var hasCover: Bool { widget.sections.contains { if case .cover = $0 { true } else { false } } }
    private var hasFields: Bool { widget.sections.contains { if case let .fields(fields) = $0 { !fields.isEmpty } else { false } } }

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(16)) {
            HStack(spacing: InterfaceScale.metric(5)) {
                Image(systemName: "sparkles").font(.interfaceSystem(size: 14)).frame(width: InterfaceScale.metric(16), height: InterfaceScale.metric(16))
                ProfileWidgetText(value: widget.header, placeholder: "Add Widget Name", limit: 50, lines: 1, size: 14, weight: .medium, markdown: false,
                                  edit: editor?.canEditPersonalWidget == true ? { value in editor?.updatePersonalWidget(id: id) { $0.header = value } } : nil)
            }
            .padding(.trailing, editor == nil ? 0 : InterfaceScale.metric(24))
            if let editor, editor.canEditPersonalWidget, !hasCover {
                ProfileWidgetSectionInsertion(title: String(localized: "Add Header", bundle: #bundle)) {
                    editor.updatePersonalWidget(id: id) { $0.sections.insert(.cover(ProfileWidgetCover()), at: 0) }
                }
            }
            ForEach(Array(widget.sections.enumerated()), id: \.offset) { index, section in
                switch section {
                case let .cover(cover):
                    if !cover.isEmpty || editor?.canEditPersonalWidget == true {
                        ProfilePersonalWidgetCover(id: id, section: index, cover: cover, animates: animates, editor: editor)
                    }
                case let .fields(fields):
                    if !fields.isEmpty {
                        ProfilePersonalWidgetFields(id: id, section: index, fields: fields, animates: animates, editor: editor, imageVisibilityOverrides: $imageVisibilityOverrides)
                    }
                }
            }
            if let editor, editor.canEditPersonalWidget, !hasFields {
                if hasCover {
                    ProfileWidgetSectionInsertion(title: String(localized: "Add Blocks", bundle: #bundle)) { addFields(2, editor: editor) }
                } else {
                    HStack(spacing: InterfaceScale.metric(16)) {
                        ProfileWidgetAddField(alwaysVisible: true) { addFields(1, editor: editor) }
                        Color.clear.frame(maxWidth: .infinity, maxHeight: InterfaceScale.metric(48))
                    }
                }
            }
            if editor == nil, expanded || hasClippedText {
                Button { expanded.toggle() } label: {
                    Text(expanded ? "Show Less" : "Show More").underline(isExpansionHovered)
                }
                .buttonStyle(.plain).font(.interfaceSystem(size: 14, weight: .medium))
                .onModalHover { isExpansionHovered = $0 }
            }
        }
        .environment(\.profileWidgetTextExpanded, editor != nil || expanded)
        .onPreferenceChange(ProfileWidgetClippedTextKey.self) { hasClippedText = $0.values.contains(true) }
        .onChange(of: widget.sections) { _, sections in
            let ids = Set(sections.flatMap { section -> [ProfileWidgetField.ID] in
                if case let .fields(fields) = section { fields.map(\.id) } else { [] }
            })
            imageVisibilityOverrides = imageVisibilityOverrides.filter { ids.contains($0.key) }
        }
        .padding(InterfaceScale.metric(16)).frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.035), in: ConcentricRectangle(cornerRadius: InterfaceScale.metric(16)))
    }

    private func addFields(_ count: Int, editor: ProfileEditorState) {
        editor.updatePersonalWidget(id: id) { personal in
            personal.sections.removeAll { if case let .fields(fields) = $0 { fields.isEmpty } else { false } }
            personal.sections.append(.fields((0 ..< count).map { _ in ProfileWidgetField() }))
        }
    }
}

private struct ProfilePersonalWidgetCover: View {
    let id: String
    let section: Int
    let cover: ProfileWidgetCover
    let animates: Bool
    let editor: ProfileEditorState?
    @State private var isHovered = false
    @State private var isTitleHovered = false
    @State private var isSubtitleHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(4)) {
            ProfileWidgetText(value: cover.title, placeholder: "Add Title", limit: 50, lines: 2, size: 24, weight: .semibold,
                              edit: editor?.canEditPersonalWidget == true ? { value in editor?.updateWidgetCover(id: id, section: section) { $0.title = value } } : nil,
                              onHoverChange: { isTitleHovered = $0 })
            ProfileWidgetText(value: cover.subtitle, placeholder: "Add description", limit: 150, lines: 3, size: 14, weight: .medium,
                              edit: editor?.canEditPersonalWidget == true ? { value in editor?.updateWidgetCover(id: id, section: section) { $0.subtitle = value } } : nil,
                              onHoverChange: { isSubtitleHovered = $0 })
        }
        .frame(maxWidth: .infinity, minHeight: cover.image != nil || editor != nil ? 54 : nil, alignment: .bottomLeading)
        .padding(cover.image != nil || editor != nil ? InterfaceScale.metric(16) : 0)
        .padding(.top, cover.image != nil || editor != nil ? InterfaceScale.metric(56) : 0)
        .foregroundStyle(cover.image == nil ? Color.primary : .white)
        .background {
            if cover.image != nil || editor?.canEditPersonalWidget == true {
                GeometryReader { geometry in
                    ProfileWidgetEditableImage(image: cover.image, purpose: .widgetCover, animates: animates, editor: editor,
                                               aspectRatio: geometry.size.width / max(geometry.size.height, 1),
                                               isCoverHovered: isHovered && !isTitleHovered && !isSubtitleHovered) { image in
                        editor?.updateWidgetCover(id: id, section: section) { $0.image = image }
                    }
                    .overlay {
                        if cover.image != nil {
                            LinearGradient(stops: [.init(color: .clear, location: 0.4), .init(color: .black, location: 1)], startPoint: .top, endPoint: .bottom)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
        }
        .clipShape(.rect(cornerRadius: InterfaceScale.metric(8)))
        .overlay(alignment: .topTrailing) {
            if let editor, editor.canEditPersonalWidget, isHovered {
                HoverActionPill {
                    HoverActionButton(systemImage: "trash", help: String(localized: "Remove Block", bundle: #bundle), role: .destructive) {
                        removeBlock()
                    }
                }
                .padding(InterfaceScale.metric(8))
            }
        }
        .onModalHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Widget Header")
        .accessibilityActions {
            if editor?.canEditPersonalWidget == true { Button("Remove Block", role: .destructive, action: removeBlock) }
        }
        .contextMenu {
            if editor?.canEditPersonalWidget == true {
                Button("Remove Block", role: .destructive, action: removeBlock)
            }
        }
    }

    private func removeBlock() {
        editor?.updatePersonalWidget(id: id) { value in
            guard value.sections.indices.contains(section), case .cover = value.sections[section] else { return }
            value.sections.remove(at: section)
        }
    }
}

private struct ProfilePersonalWidgetFields: View {
    let id: String
    let section: Int
    let fields: [ProfileWidgetField]
    let animates: Bool
    let editor: ProfileEditorState?
    @Binding var imageVisibilityOverrides: [ProfileWidgetField.ID: Bool]

    var body: some View {
        LazyVGrid(
            columns: [.init(.flexible(), spacing: InterfaceScale.metric(16), alignment: .topLeading), .init(.flexible(), spacing: InterfaceScale.metric(16), alignment: .topLeading)],
            alignment: .leading,
            spacing: InterfaceScale.metric(16)
        ) {
            ForEach(fields.filter { !$0.isEmpty || editor?.canEditPersonalWidget == true }) { field in
                ProfilePersonalWidgetField(id: id, section: section, field: field, animates: animates, editor: editor, imageVisibilityOverrides: $imageVisibilityOverrides)
            }
            if let editor, editor.canEditPersonalWidget, fields.count % 2 == 1, fields.count < 4 {
                ProfileWidgetAddField { editor.addWidgetFields(id: id, section: section, count: 1) }
            }
        }
        if let editor, editor.canEditPersonalWidget, fields.count % 2 == 0, fields.count < 4 {
            ProfileWidgetSectionInsertion(title: String(localized: "Add Blocks", bundle: #bundle)) {
                editor.addWidgetFields(id: id, section: section, count: 2)
            }
        }
    }
}

private struct ProfilePersonalWidgetField: View {
    let id: String
    let section: Int
    let field: ProfileWidgetField
    let animates: Bool
    let editor: ProfileEditorState?
    @Binding var imageVisibilityOverrides: [ProfileWidgetField.ID: Bool]
    @State private var isHovered = false
    @State private var isActionHovered = false
    @State private var isImageHovered = false

    private var showsActions: Bool { (isHovered || isActionHovered) && !isImageHovered }

    private var hidesImage: Bool {
        if let hidden = imageVisibilityOverrides[field.id] { return hidden }
        let original = editor?.snapshot?.presentation.widgets?.first { $0.id == id }
        if case let .personal(personal) = original?.content {
            return field.image == nil && personal.sections.contains { value in
                if case let .fields(fields) = value { return fields.contains { $0.id == field.id && $0.image == nil } }
                return false
            }
        }
        return false
    }

    var body: some View {
        HStack(alignment: .top, spacing: InterfaceScale.metric(12)) {
            if field.image != nil || (editor?.canEditPersonalWidget == true && !hidesImage) {
                ProfileWidgetEditableImage(image: field.image, purpose: .widgetField, animates: animates, editor: editor, aspectRatio: 1, onHoverChange: { isImageHovered = $0 }, removeImage: {
                    imageVisibilityOverrides[field.id] = true
                    editor?.updateWidgetField(id: id, section: section, fieldID: field.id) { $0.image = nil }
                }, update: { image in
                    editor?.updateWidgetField(id: id, section: section, fieldID: field.id) { $0.image = image }
                })
                .frame(width: InterfaceScale.metric(48), height: InterfaceScale.metric(48))
                .contextMenu {
                    if editor?.canEditPersonalWidget == true, field.image == nil { Button("Remove Image") { imageVisibilityOverrides[field.id] = true } }
                }
            }
            VStack(alignment: .leading, spacing: InterfaceScale.metric(4)) {
                ProfileWidgetText(value: field.title, placeholder: "Add title", limit: 40, lines: 2, size: 14, weight: .medium,
                                  edit: editor?.canEditPersonalWidget == true ? { value in editor?.updateWidgetField(id: id, section: section, fieldID: field.id) { $0.title = value } } : nil)
                ProfileWidgetText(value: field.description, placeholder: "Add description", limit: 90, lines: 4, size: 12,
                                  edit: editor?.canEditPersonalWidget == true ? { value in editor?.updateWidgetField(id: id, section: section, fieldID: field.id) { $0.description = value } } : nil)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .overlay(alignment: .topTrailing) {
            if let editor, editor.canEditPersonalWidget, showsActions {
                HoverActionPill {
                    if hidesImage {
                        HoverActionButton(systemImage: "photo.badge.plus", help: String(localized: "Add Image", bundle: #bundle)) { imageVisibilityOverrides[field.id] = false }
                    }
                    HoverActionButton(systemImage: "trash", help: String(localized: "Remove Block", bundle: #bundle), role: .destructive) {
                        editor.removeWidgetField(id: id, section: section, fieldID: field.id)
                    }
                }
                .onModalHover { isActionHovered = $0 }
                .onDisappear { isActionHovered = false }
                .offset(x: InterfaceScale.metric(8), y: -12)
            }
        }
        .onModalHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Widget Field")
        .accessibilityActions {
            if let editor, editor.canEditPersonalWidget {
                if hidesImage {
                    Button("Add Image") { imageVisibilityOverrides[field.id] = false }
                } else {
                    Button("Remove Image", role: .destructive) {
                        imageVisibilityOverrides[field.id] = true
                        editor.updateWidgetField(id: id, section: section, fieldID: field.id) { $0.image = nil }
                    }
                }
                Button("Remove Block", role: .destructive) { editor.removeWidgetField(id: id, section: section, fieldID: field.id) }
            }
        }
        .contextMenu {
            if let editor, editor.canEditPersonalWidget {
                if hidesImage { Button("Add Image") { imageVisibilityOverrides[field.id] = false } }
                Button("Remove Block", role: .destructive) { editor.removeWidgetField(id: id, section: section, fieldID: field.id) }
            }
        }
    }
}

struct ProfileWidgetText: View {
    let value: String
    let placeholder: LocalizedStringKey
    let limit: Int
    let lines: Int
    let size: CGFloat
    var weight: Font.Weight = .regular
    var markdown = true
    var edit: ((String) -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    @Environment(\.profileWidgetTextExpanded) private var expanded
    @State private var measurementID = UUID()
    @State private var fullHeight: CGFloat = 0
    @State private var displayedHeight: CGFloat = 0
    @State private var draft = ""
    @State private var originalValue = ""
    @State private var isEditing = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if isEditing {
                ProfileInlineTextLayout {
                    Group {
                        if draft.isEmpty { Text(placeholder) } else { Text(draft) }
                    }
                    .hidden().accessibilityHidden(true)
                    TextField(placeholder, text: Binding(get: { draft }, set: { updateDraft($0) }), axis: lines > 1 ? .vertical : .horizontal)
                        .textFieldStyle(.plain).lineLimit(1 ... lines).focused($focused)
                        .onSubmit(commit)
                        .onKeyPress(.return, phases: .down) { event in
                            guard lines == 1 || !event.modifiers.contains(.shift) else { return .ignored }
                            commit(); return .handled
                        }
                        .onKeyPress(.escape, phases: .down) { _ in cancel(); return .handled }
                        .onExitCommand(perform: cancel)
                        .onChange(of: focused) { _, value in if !value { commit() } }
                }
            } else if edit != nil {
                Button { originalValue = value; draft = value; isEditing = true; focused = true } label: {
                    if value.isEmpty { Text(placeholder).italic().foregroundStyle(.secondary) } else { renderedText }
                }.buttonStyle(.plain).accessibilityLabel(placeholder).accessibilityValue(value)
            } else if !value.isEmpty { renderedText }
        }
        .font(.interfaceSystem(size: size, weight: weight))
        .multilineTextAlignment(.leading)
        .frame(minWidth: 0, alignment: .leading)
        .clipped()
        .profileEditorTextHover(isEnabled: edit != nil, isEditing: isEditing)
        .onModalHover { onHoverChange?($0) }
        .onDisappear { onHoverChange?(false) }
        .frame(maxWidth: .infinity, alignment: .leading)
        .preference(key: ProfileWidgetClippedTextKey.self, value: [measurementID: !isEditing && fullHeight - displayedHeight > 1])
        .onChange(of: edit != nil) { _, available in
            if !available { isEditing = false; focused = false }
        }
        .onChange(of: value) { _, value in
            guard isEditing, value != draft.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            draft = value
            isEditing = false; focused = false
        }
    }

    private var renderedText: some View {
        let content = markdown
            ? DiscordMarkdown.profileWidgetAttributed(value, font: .interfaceSystem(size: size, weight: weight), links: edit == nil)
            : AttributedString(value)
        return Text(content)
            .font(.interfaceSystem(size: size, weight: weight))
            .lineLimit(expanded ? nil : lines)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { displayedHeight = $0 }
            .background(alignment: .topLeading) {
                Text(content).fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                    .hidden().accessibilityHidden(true).allowsHitTesting(false)
            }
            .environment(\.openURL, OpenURLAction { url in
                _ = MessageLinkActivator.activate(url, model: nil, displayedText: nil)
                return .handled
            })
    }

    private func commit() {
        guard isEditing else { return }
        isEditing = false; focused = false
    }

    private func updateDraft(_ value: String) {
        guard isEditing else { return }
        var length = 0
        draft = String(value.prefix { length += $0.utf16.count; return length <= limit })
        edit?(draft.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func cancel() {
        guard isEditing else { return }
        draft = originalValue
        isEditing = false; focused = false
        edit?(originalValue)
    }
}

private extension EnvironmentValues {
    @Entry var profileWidgetTextExpanded = false
}

private struct ProfileWidgetClippedTextKey: PreferenceKey {
    static let defaultValue: [UUID: Bool] = [:]
    static func reduce(value: inout [UUID: Bool], nextValue: () -> [UUID: Bool]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}
