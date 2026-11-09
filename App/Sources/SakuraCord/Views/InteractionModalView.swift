import SakuraCordModels
import SwiftUI
import UniformTypeIdentifiers

/// A form an application returned for an interaction. Cancelling is local;
/// submitting sends one interaction with the entered values.
struct InteractionModalView: View {
    let model: AppModel
    let form: InteractionModalFormState
    @Environment(\.windowModalContext) private var dismiss
    @Environment(\.windowModalAvailableSize) private var availableSize
    @FocusState private var focusedField: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: InterfaceScale.metric(14)) {
                        ForEach(form.modal.nodes) { node in
                            nodeView(node)
                        }
                        if !form.isSubmittable {
                            Label(
                                "This form uses a field SakuraCord can’t show yet, so it can’t be submitted here.",
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.interface(.callout))
                            .foregroundStyle(.orange)
                        }
                    }
                    .padding(.horizontal, InterfaceScale.metric(18))
                    .padding(.vertical, InterfaceScale.metric(16))
                    .disabled(form.isSubmitting)
                }
                .scrollBounceBehavior(.always, axes: .vertical)
                .frame(maxHeight: min(600, max(200, availableSize.height - 180)))
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: form.focusRequest) { _, request in
                    guard let request else { return }
                    withAnimation(.snappy) { proxy.scrollTo(request, anchor: .center) }
                    focusedField = request
                    form.consumeFocusRequest()
                }
            }
            if let error = form.formError {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.interface(.callout))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, InterfaceScale.metric(18))
                    .padding(.bottom, InterfaceScale.metric(12))
            }
            Divider()
            HStack {
                ModalGlassButton(symbol: "xmark", label: "Cancel") { dismiss?() }
                    .disabled(form.isSubmitting)
                Spacer(minLength: InterfaceScale.metric(16))
                ModalGlassButton(symbol: "paperplane.fill", label: "Submit", primary: true, isLoading: form.isSubmitting, action: submit)
                    .disabled(form.isSubmitting || !form.isSubmittable)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(InterfaceScale.metric(12))
        }
        .frame(width: min(500, availableSize.width))
        .task {
            await Task.yield()
            focusedField = form.controls.first { control in
                if case .textInput = control.kind { return true }
                return false
            }?.customID
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(form.modal.title)
    }

    private var header: some View {
        HStack(spacing: InterfaceScale.metric(12)) {
            CommandApplicationIcon(application: form.modal.application, size: InterfaceScale.metric(34))
            VStack(alignment: .leading, spacing: 1) {
                Text(form.modal.title)
                    .font(.interfaceSystem(size: 17, weight: .semibold))
                    .lineLimit(2)
                Text(form.modal.application.name)
                    .font(.interface(.callout))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, InterfaceScale.metric(18))
        .padding(.vertical, InterfaceScale.metric(14))
    }

    private func submit() {
        model.submitInteractionModal(form)
    }

    // MARK: Nodes

    private func nodeView(_ node: ModalNode) -> AnyView {
        switch node {
        case let .actionRow(_, children):
            return AnyView(VStack(alignment: .leading, spacing: InterfaceScale.metric(14)) {
                ForEach(children) { nodeView($0) }
            })
        case let .label(_, label, description, child):
            if case let .control(control) = child, case .checkbox = control.kind {
                return AnyView(InteractionModalCheckboxRow(form: form, control: control, label: label, description: description))
            }
            return AnyView(InteractionModalFieldGroup(
                label: label,
                description: description,
                isRequired: child.controls.contains(where: \.isRequired),
                error: child.controls.first.flatMap { form.errors[$0.customID] }
            ) {
                nodeView(child)
            }
            .id(child.controls.first?.customID ?? node.id))
        case let .textDisplay(_, content):
            return AnyView(
                Text(Self.markdown(content))
                    .font(.interface(.body))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            )
        case let .control(control):
            if let label = control.label {
                // Legacy rows carry the label on the text input itself.
                return AnyView(InteractionModalFieldGroup(
                    label: label, description: nil, isRequired: control.isRequired,
                    error: form.errors[control.customID]
                ) {
                    controlView(control)
                }
                .id(control.customID))
            }
            return controlView(control)
        case let .unsupported(_, type):
            return AnyView(
                Label("Unsupported form field (type \(type))", systemImage: "questionmark.square.dashed")
                    .font(.interface(.callout))
                    .foregroundStyle(.secondary)
            )
        }
    }

    private func controlView(_ control: ModalControl) -> AnyView {
        switch control.kind {
        case let .textInput(style, placeholder, _, maximum, _):
            AnyView(InteractionModalTextField(
                form: form, control: control, style: style, placeholder: placeholder,
                maximum: maximum, focus: $focusedField, submit: submit
            ))
        case let .select(kind, placeholder, options, _, maximum, channelTypes, _):
            if kind == .string {
                AnyView(InteractionModalStringSelect(
                    form: form, control: control, placeholder: placeholder, options: options,
                    maximum: maximum
                ))
            } else {
                AnyView(InteractionModalEntitySelect(
                    model: model, form: form, control: control, kind: kind,
                    placeholder: placeholder, maximum: maximum, channelTypes: channelTypes
                ))
            }
        case let .radioGroup(options):
            AnyView(InteractionModalRadioGroup(form: form, control: control, options: options))
        case let .checkboxGroup(options, _, maximum):
            AnyView(InteractionModalCheckboxGroup(form: form, control: control, options: options, maximum: maximum))
        case .checkbox:
            AnyView(InteractionModalCheckboxRow(form: form, control: control, label: control.label ?? "", description: nil))
        case let .fileUpload(_, maximum, fileTypes):
            AnyView(InteractionModalFileUpload(
                model: model, form: form, control: control, maximum: maximum, fileTypes: fileTypes
            ))
        }
    }

    static func markdown(_ content: String) -> AttributedString {
        (try? AttributedString(
            markdown: content,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(content)
    }
}

private struct InteractionModalFieldGroup<Content: View>: View {
    let label: String
    let description: String?
    let isRequired: Bool
    let error: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(6)) {
            HStack(spacing: InterfaceScale.metric(3)) {
                Text(label).font(.interfaceSystem(size: 13, weight: .semibold))
                if isRequired {
                    Text("*").font(.interfaceSystem(size: 13, weight: .semibold)).foregroundStyle(.red)
                        .accessibilityLabel("required")
                }
            }
            if let description, !description.isEmpty {
                Text(InteractionModalView.markdown(description))
                    .font(.interface(.callout))
                    .foregroundStyle(.secondary)
            }
            content()
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.interface(.callout))
                    .foregroundStyle(.red)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Shared input surface: a soft rounded field like the rest of SakuraCord's forms.
struct InteractionModalFieldBackground: ViewModifier {
    var isFocused = false
    var hasError = false
    var cornerRadius: CGFloat = InterfaceScale.metric(14)
    /// Focuses the field from a click anywhere in its surface, padding
    /// included, rather than only on the field's own text.
    var focus: (() -> Void)?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let surface = content
            .background(.quaternary.opacity(isFocused ? 0.8 : 0.5), in: shape)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        hasError ? Color.red.opacity(0.8)
                            : (isFocused ? SakuraCordAccentColor.color.opacity(0.7) : .clear),
                        lineWidth: 1.5
                    )
            }
        if let focus {
            surface.contentShape(shape).onTapGesture(perform: focus)
        } else {
            surface
        }
    }
}

private struct InteractionModalTextField: View {
    let form: InteractionModalFormState
    let control: ModalControl
    let style: ModalTextInputStyle
    let placeholder: String?
    let maximum: Int?
    var focus: FocusState<String?>.Binding
    let submit: () -> Void

    var body: some View {
        let binding = Binding(get: { form.text(for: control) }, set: { form.setText($0, for: control) })
        let count = form.text(for: control).unicodeScalars.count
        VStack(alignment: .trailing, spacing: InterfaceScale.metric(3)) {
            Group {
                if style == .paragraph {
                    TextField(placeholder ?? "", text: binding, axis: .vertical)
                        .lineLimit(3 ... 10)
                } else {
                    TextField(placeholder ?? "", text: binding)
                        .onSubmit(submit)
                }
            }
            .textFieldStyle(.plain)
            .tint(SakuraCordAccentColor.color)
            .focused(focus, equals: control.customID)
            .disabled(control.isDisabled)
            .padding(.horizontal, InterfaceScale.metric(11))
            .padding(.vertical, InterfaceScale.metric(9))
            .modifier(InteractionModalFieldBackground(
                isFocused: focus.wrappedValue == control.customID,
                hasError: form.errors[control.customID] != nil,
                focus: control.isDisabled ? nil : { focus.wrappedValue = control.customID }
            ))
            if let maximum, count > maximum * 3 / 4 || style == .paragraph {
                Text("\(count)/\(maximum)")
                    .font(.interface(.caption))
                    .monospacedDigit()
                    .foregroundStyle(count >= maximum ? .orange : .secondary)
            }
        }
    }
}

private struct InteractionModalStringSelect: View {
    let form: InteractionModalFormState
    let control: ModalControl
    let placeholder: String?
    let options: [ComponentSelectOption]
    let maximum: Int

    var body: some View {
        SelectionField(
            selection: Binding(
                get: { form.selectedValues(for: control) },
                set: { form.setSelection($0, for: control) }
            ),
            mode: maximum == 1 ? .single : .multiple(maximum: maximum),
            source: .local(options: options.map {
                ComponentChoiceOptionPresentation.fieldOption($0, selectKind: .string)
            }),
            configuration: .init(
                placeholder: placeholder ?? (maximum > 1 ? "Make selections" : "Make a selection"),
                searchPlaceholder: "Search options"
            ),
            accessibilityIdentifier: "modal-select-\(control.customID)"
        )
        .disabled(control.isDisabled || form.isSubmitting)
    }
}

private struct InteractionModalEmoji: View {
    let emoji: EmojiReference

    var body: some View {
        if let url = emoji.imageURL(size: 48) {
            AnimatedRemoteImage(url: url).frame(width: InterfaceScale.metric(20), height: InterfaceScale.metric(20))
        } else {
            Text(emoji.name).font(.interfaceSystem(size: 17))
        }
    }
}

private struct InteractionModalEntitySelect: View {
    let model: AppModel
    let form: InteractionModalFormState
    let control: ModalControl
    let kind: ComponentSelectKind
    let placeholder: String?
    let maximum: Int
    let channelTypes: [Int]
    @State private var knownOptions: [String: ComponentSelectOption] = [:]

    var body: some View {
        let initial = initialOptions
        SelectionField(
            selection: Binding(
                get: { form.selectedValues(for: control) },
                set: { values in
                    let options = Dictionary(initial.map { ($0.value, $0) }, uniquingKeysWith: { _, newer in newer })
                    form.setEntitySelection(values.compactMap { knownOptions[$0] ?? options[$0] }, for: control)
                }
            ),
            mode: maximum == 1 ? .single : .multiple(maximum: maximum),
            source: .dynamic(
                initialOptions: initial.map { ComponentChoiceOptionPresentation.fieldOption($0, selectKind: kind) },
                debounce: .milliseconds(250),
                maximumResults: 50,
                search: { query in
                    var results = local(query: query)
                    if kind != .channel, model.supportsCapability(.remoteComponentChoices) {
                        do {
                            let remote = try await model.componentChoices(
                                kind: kind, query: query, guildID: form.modal.guildID, channelID: form.modal.channelID
                            )
                            var seen = Set(results.map(\.value))
                            results += remote.filter { seen.insert($0.value).inserted }
                        } catch {
                            if results.isEmpty { throw error }
                        }
                    }
                    try Task.checkCancellation()
                    // Retain selected metadata across searches, without accumulating every result.
                    knownOptions = Dictionary(
                        (results + form.entitySelection(for: control)).map { ($0.value, $0) },
                        uniquingKeysWith: { _, newer in newer }
                    )
                    return results.map { ComponentChoiceOptionPresentation.fieldOption($0, selectKind: kind) }
                }
            ),
            configuration: .init(placeholder: placeholder ?? defaultPlaceholder, searchPlaceholder: "Search options"),
            accessibilityIdentifier: "modal-select-\(control.customID)"
        )
        .disabled(control.isDisabled || form.isSubmitting)
    }

    private var initialOptions: [ComponentSelectOption] {
        var seen = Set<String>()
        return (form.entitySelection(for: control) + local(query: ""))
            .filter { seen.insert($0.value).inserted }
    }

    private func local(query: String) -> [ComponentSelectOption] {
        model.cachedComponentChoices(
            kind: kind, guildID: form.modal.guildID, channelTypes: channelTypes, limit: 50, query: query
        )
    }

    private var defaultPlaceholder: String {
        switch kind {
        case .user: maximum > 1 ? "Choose members" : "Choose a member"
        case .role: maximum > 1 ? "Choose roles" : "Choose a role"
        case .mentionable: "Choose members or roles"
        case .channel: maximum > 1 ? "Choose channels" : "Choose a channel"
        case .string: "Make a selection"
        }
    }
}

private struct InteractionModalRadioGroup: View {
    let form: InteractionModalFormState
    let control: ModalControl
    let options: [ComponentSelectOption]

    var body: some View {
        let selected = form.radioValue(for: control)
        VStack(spacing: InterfaceScale.metric(4)) {
            ForEach(options) { option in
                let isSelected = selected == option.value
                Button { form.setRadio(option.value, for: control) } label: {
                    InteractionModalChoiceRow(
                        option: option,
                        symbol: isSelected ? "largecircle.fill.circle" : "circle",
                        isSelected: isSelected
                    )
                }
                .buttonStyle(.plain)
                .disabled(control.isDisabled)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

private struct InteractionModalCheckboxGroup: View {
    let form: InteractionModalFormState
    let control: ModalControl
    let options: [ComponentSelectOption]
    let maximum: Int

    var body: some View {
        let selected = form.selectedValues(for: control)
        VStack(spacing: InterfaceScale.metric(4)) {
            ForEach(options) { option in
                let isSelected = selected.contains(option.value)
                // Discord disables unchecked choices once the maximum is reached.
                let isAvailable = isSelected || selected.count < maximum
                Button { form.toggleCheckboxGroupValue(option.value, for: control) } label: {
                    InteractionModalChoiceRow(
                        option: option,
                        symbol: isSelected ? "checkmark.square.fill" : "square",
                        isSelected: isSelected
                    )
                }
                .buttonStyle(.plain)
                .disabled(control.isDisabled || !isAvailable)
                .opacity(isAvailable ? 1 : 0.45)
            }
        }
    }
}

struct InteractionModalChoiceRow: View {
    let option: ComponentSelectOption
    let symbol: String
    let isSelected: Bool

    init(option: ComponentSelectOption, symbol: String, isSelected: Bool) {
        self.option = option
        self.symbol = symbol
        self.isSelected = isSelected
    }

    init(label: String, symbol: String, isSelected: Bool) {
        self.init(option: .init(label: label, value: label), symbol: symbol, isSelected: isSelected)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: InterfaceScale.metric(10)) {
            Image(systemName: symbol)
                .font(.interfaceSystem(size: 16))
                .foregroundStyle(isSelected ? AnyShapeStyle(SakuraCordAccentColor.color) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: InterfaceScale.metric(6)) {
                    if let emoji = option.emoji { InteractionModalEmoji(emoji: emoji) }
                    Text(option.label).foregroundStyle(.primary)
                }
                if let description = option.description {
                    Text(description).font(.interface(.callout)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, InterfaceScale.metric(11))
        .padding(.vertical, InterfaceScale.metric(8))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .modifier(InteractionModalFieldBackground(isFocused: isSelected))
    }
}

private struct InteractionModalCheckboxRow: View {
    let form: InteractionModalFormState
    let control: ModalControl
    let label: String
    let description: String?

    var body: some View {
        let isChecked = form.isChecked(control)
        // Same row as checkbox-group choices so every modal control shares one shape.
        Button { form.setChecked(!isChecked, for: control) } label: {
            HStack(alignment: .firstTextBaseline, spacing: InterfaceScale.metric(10)) {
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .font(.interfaceSystem(size: 16))
                    .foregroundStyle(isChecked ? AnyShapeStyle(SakuraCordAccentColor.color) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).foregroundStyle(.primary)
                    if let description, !description.isEmpty {
                        Text(InteractionModalView.markdown(description)).font(.interface(.callout)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, InterfaceScale.metric(11))
            .padding(.vertical, InterfaceScale.metric(8))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .modifier(InteractionModalFieldBackground(isFocused: isChecked))
        }
        .buttonStyle(.plain)
        .disabled(control.isDisabled)
        .accessibilityAddTraits(isChecked ? [.isButton, .isSelected] : .isButton)
        .id(control.customID)
    }
}

private struct InteractionModalFileUpload: View {
    let model: AppModel
    let form: InteractionModalFormState
    let control: ModalControl
    let maximum: Int
    let fileTypes: [String]
    @State private var isImporterPresented = false
    @State private var isDropTarget = false

    var body: some View {
        let files = form.files(for: control)
        VStack(alignment: .leading, spacing: InterfaceScale.metric(6)) {
            ForEach(files) { file in
                HStack(spacing: InterfaceScale.metric(9)) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                        .resizable().scaledToFit().frame(width: InterfaceScale.metric(26), height: InterfaceScale.metric(26))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.name).lineLimit(1).truncationMode(.middle)
                        if let size = file.byteCount {
                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                .font(.interface(.caption)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: InterfaceScale.metric(6))
                    HoverActionButton(systemImage: "xmark", help: "Remove \(file.name)", diameter: InterfaceScale.metric(26)) {
                        form.removeFile(file, from: control)
                    }
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, InterfaceScale.metric(9))
                .padding(.vertical, InterfaceScale.metric(6))
                .modifier(InteractionModalFieldBackground())
            }
            if files.count < maximum {
                Button { isImporterPresented = true } label: {
                    VStack(spacing: InterfaceScale.metric(4)) {
                        Image(systemName: "arrow.up.doc").font(.interface(.title3))
                        Text("Drop files here or click to browse").font(.interface(.callout))
                        Text(hint).font(.interface(.caption)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: InterfaceScale.metric(74))
                    .contentShape(Rectangle())
                    .background(
                        .quaternary.opacity(isDropTarget ? 0.9 : 0.35),
                        in: RoundedRectangle(cornerRadius: InterfaceScale.metric(14), style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: InterfaceScale.metric(14), style: .continuous)
                            .strokeBorder(
                                form.errors[control.customID] != nil ? Color.red.opacity(0.8) : Color.secondary.opacity(0.5),
                                style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                            )
                    }
                }
                .buttonStyle(.plain)
                .disabled(control.isDisabled)
                .dropDestination(for: URL.self) { urls, _ in
                    add(urls)
                    return true
                } isTargeted: { isDropTarget = $0 }
            } else {
                Label("File upload limit reached. Remove some files to upload new ones.", systemImage: "tray.full")
                    .font(.interface(.callout))
                    .foregroundStyle(.secondary)
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: InteractionModalFormState.contentTypes(for: fileTypes),
            allowsMultipleSelection: maximum - files.count > 1
        ) { result in
            guard case let .success(urls) = result else { return }
            add(urls)
        }
    }

    private var hint: String {
        let limit = maximum == 1 ? "One file" : "Up to \(maximum) files"
        guard let types = InteractionModalFormState.fileTypeDescription(fileTypes) else { return limit }
        return "\(limit) · \(types)"
    }

    private func add(_ urls: [URL]) {
        Task {
            let accepted = await model.attachmentURLsWithinDiscordLimit(urls)
            form.addFiles(accepted, to: control)
        }
    }
}
