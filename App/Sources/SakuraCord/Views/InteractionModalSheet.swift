import SakuraCordModels
import SwiftUI
import UniformTypeIdentifiers

struct InteractionModalSheet: View {
    let model: AppModel
    let modal: InteractionModal
    @State private var values: [String: [String]] = [:]
    @State private var fileURLs: [String: [URL]] = [:]
    @State private var activeFileControlID: String?
    @State private var validationMessage: String?
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(modal.title).font(.title2.bold())
                Spacer()
                Button {
                    model.dismissInteractionModal()
                } label: {
                    Image(systemName: "xmark")
                }.buttonStyle(.plain).help("Cancel")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) { ForEach(modal.controls) { controlView($0) } }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let validationMessage {
                Text(validationMessage).font(.caption).foregroundStyle(.red)
            }
            if let error = model.interactionErrorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { model.dismissInteractionModal() }.keyboardShortcut(.cancelAction)
                Button("Submit") { submit() }.buttonStyle(.borderedProminent).keyboardShortcut(
                    .defaultAction
                ).disabled(isSubmitting)
            }
        }
        .padding(20).frame(minWidth: 480, idealWidth: 540, minHeight: 300, idealHeight: 460)
        .onAppear { for control in modal.controls {
            seed(control)
        } }
        .fileImporter(
            isPresented: Binding(
                get: { activeFileControlID != nil }, set: {
                    if !$0 {
                        activeFileControlID = nil
                    }
                }
            ),
            allowedContentTypes: [.item], allowsMultipleSelection: true
        ) { result in
            guard let id = activeFileControlID else { return }
            if case let .success(urls) = result {
                fileURLs[id] = model.attachmentURLsWithinDiscordLimit(urls)
            }
            activeFileControlID = nil
        }
    }

    private func controlView(_ control: ModalControl) -> AnyView {
        switch control {
        case let .label(_, label, description, child):
            AnyView(
                VStack(alignment: .leading, spacing: 6) {
                    Text(label).font(.headline)
                    if let description {
                        Text(description).font(.caption).foregroundStyle(.secondary)
                    }
                    controlView(child)
                }
            )
        case let .textInput(_, customID, style, label, _, placeholder, _, _, _):
            AnyView(
                VStack(alignment: .leading, spacing: 5) {
                    if let label {
                        Text(label).font(.headline)
                    }
                    if style == 2 {
                        TextField(placeholder ?? "", text: textBinding(customID), axis: .vertical).lineLimit(
                            3 ... 10
                        )
                        .tint(SakuraCordAccentColor.color)
                    } else {
                        TextField(placeholder ?? "", text: textBinding(customID))
                            .tint(SakuraCordAccentColor.color)
                    }
                }
                .textFieldStyle(.roundedBorder)
            )
        case let .select(_, customID, _, options, _, _, _):
            AnyView(
                Picker("Selection", selection: textBinding(customID)) {
                    ForEach(options) { Text($0.label).tag($0.value) }
                }.pickerStyle(.menu)
            )
        case let .fileUpload(_, customID, _, _, maxValues):
            AnyView(
                HStack {
                    Button("Choose files…") { activeFileControlID = customID }
                    Text(
                        fileURLs[customID]?.map(\.lastPathComponent).joined(separator: ", ")
                            ?? "No files selected"
                    ).lineLimit(1).foregroundStyle(.secondary)
                    Text("Up to \(maxValues)").font(.caption).foregroundStyle(.tertiary)
                }
            )
        case let .radioGroup(_, customID, options, _):
            AnyView(
                Picker("Choice", selection: textBinding(customID)) {
                    ForEach(options) { Text($0.label).tag($0.value) }
                }.pickerStyle(.radioGroup)
            )
        case let .checkboxGroup(_, customID, options, _, _):
            AnyView(
                VStack(alignment: .leading) {
                    ForEach(options) { option in
                        Toggle(option.label, isOn: membershipBinding(customID, value: option.value))
                    }
                }
            )
        case let .checkbox(_, customID, label, _):
            AnyView(Toggle(label, isOn: boolBinding(customID)))
        case let .unsupported(_, type):
            AnyView(
                Label("Unsupported form control \(type)", systemImage: "questionmark.square.dashed")
                    .foregroundStyle(.secondary)
            )
        }
    }

    private func textBinding(_ id: String) -> Binding<String> {
        Binding(get: { values[id]?.first ?? "" }, set: { values[id] = [$0] })
    }

    private func boolBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { values[id]?.first == "true" }, set: { values[id] = [$0 ? "true" : "false"] })
    }

    private func membershipBinding(_ id: String, value: String) -> Binding<Bool> {
        Binding(
            get: { values[id, default: []].contains(value) },
            set: { active in
                var selected = values[id, default: []]
                if active {
                    if !selected.contains(value) {
                        selected.append(value)
                    }
                } else {
                    selected.removeAll { $0 == value }
                }
                values[id] = selected
            }
        )
    }

    private func seed(_ control: ModalControl) {
        switch control {
        case let .label(_, _, _, child): seed(child)
        case let .textInput(_, customID, _, _, value, _, _, _, _): values[customID] = [value ?? ""]
        case let .select(_, customID, _, options, _, _, _),
             let .radioGroup(_, customID, options, _):
            values[customID] = options.first(where: \.isDefault).map { [$0.value] } ?? []
        case let .checkbox(_, customID, _, value): values[customID] = [value ? "true" : "false"]
        default: break
        }
    }

    private func validate(_ control: ModalControl) -> String? {
        switch control {
        case let .label(_, _, _, child): return validate(child)
        case let .textInput(_, customID, _, label, _, _, required, minLength, maxLength):
            let count = values[customID]?.first?.count ?? 0
            if required, count == 0 {
                return "\(label ?? "A text field") is required."
            }
            if let minLength, count < minLength {
                return "\(label ?? "Text") needs at least \(minLength) characters."
            }
            if let maxLength, count > maxLength {
                return "\(label ?? "Text") allows at most \(maxLength) characters."
            }
            return nil
        case let .select(_, customID, _, _, required, minValues, maxValues):
            return validateCount(
                values[customID]?.count ?? 0, id: customID, required: required, minimum: minValues,
                maximum: maxValues
            )
        case let .fileUpload(_, customID, required, minValues, maxValues):
            return validateCount(
                fileURLs[customID]?.count ?? 0, id: customID, required: required, minimum: minValues,
                maximum: maxValues
            )
        case let .radioGroup(_, customID, _, required):
            return required && values[customID, default: []].isEmpty ? "A choice is required." : nil
        case let .checkboxGroup(_, customID, _, minValues, maxValues):
            return validateCount(
                values[customID]?.count ?? 0, id: customID, required: minValues > 0, minimum: minValues,
                maximum: maxValues
            )
        default: return nil
        }
    }

    private func validateCount(_ count: Int, id: String, required: Bool, minimum: Int, maximum: Int)
        -> String?
    {
        if required, count < max(1, minimum) {
            return "\(id) needs at least \(max(1, minimum)) selection."
        }
        if count > maximum {
            return "\(id) allows at most \(maximum) selections."
        }
        return nil
    }

    private func submit() {
        validationMessage = modal.controls.compactMap(validate).first
        guard validationMessage == nil else { return }
        isSubmitting = true
        Task {
            let succeeded = await model.submitModal(values: values, fileURLs: fileURLs)
            if !succeeded {
                isSubmitting = false
            }
        }
    }
}
