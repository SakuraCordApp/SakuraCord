import Foundation
import Observation
import SakuraCordModels
import UniformTypeIdentifiers

/// A file the person chose for a form upload control. Upload happens on submit.
struct InteractionModalFile: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let byteCount: Int64?

    var name: String { url.lastPathComponent }
}

/// Draft editing, validation and submission status for one returned form.
/// Transport stays in the provider; this owns what the person has entered.
@MainActor
@Observable
final class InteractionModalFormState: Identifiable {
    /// Each control remembers whether the person changed it, because an
    /// untouched control without a default submits null while a cleared one
    /// submits an empty value.
    enum Field: Equatable {
        case text(String, isEdited: Bool)
        case selection([String], isEdited: Bool)
        case radio(String?, isEdited: Bool)
        case checkbox(Bool)
        case files([InteractionModalFile])
    }

    nonisolated var id: String { modal.interactionID }
    let modal: InteractionModal
    let controls: [ModalControl]
    private(set) var fields: [String: Field] = [:]
    /// Display metadata for chosen entities, in selection order.
    private(set) var entitySelections: [String: [ComponentSelectOption]] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var formError: String?
    private(set) var isSubmitting = false
    private(set) var focusRequest: String?

    init(modal: InteractionModal) {
        self.modal = modal
        controls = modal.controls
        for control in controls {
            fields[control.customID] = Self.initialField(for: control)
            if case let .select(kind, _, _, _, _, _, defaults) = control.kind, kind != .string {
                entitySelections[control.customID] = defaults.map {
                    Self.defaultEntityOption($0, resolved: modal.resolved)
                }
            }
        }
    }

    var isSubmittable: Bool { modal.isSubmittable }

    // MARK: Reading

    func text(for control: ModalControl) -> String {
        guard case let .text(text, _)? = fields[control.customID] else { return "" }
        return text
    }

    func selectedValues(for control: ModalControl) -> [String] {
        guard case let .selection(values, _)? = fields[control.customID] else { return [] }
        return values
    }

    func radioValue(for control: ModalControl) -> String? {
        guard case let .radio(value, _)? = fields[control.customID] else { return nil }
        return value
    }

    func isChecked(_ control: ModalControl) -> Bool {
        guard case let .checkbox(value)? = fields[control.customID] else { return false }
        return value
    }

    func files(for control: ModalControl) -> [InteractionModalFile] {
        guard case let .files(files)? = fields[control.customID] else { return [] }
        return files
    }

    func entitySelection(for control: ModalControl) -> [ComponentSelectOption] {
        entitySelections[control.customID] ?? []
    }

    // MARK: Editing

    func setText(_ text: String, for control: ModalControl) {
        guard case let .textInput(_, _, _, maximum, _) = control.kind else { return }
        // Discord truncates input beyond the maximum rather than rejecting it.
        let limited = maximum.map { Self.truncated(text, toScalarCount: $0) } ?? text
        // Focusing a field can echo its current value back; that is not an edit,
        // and an untouched field must still submit null.
        if case let .text(current, _)? = fields[control.customID], current == limited { return }
        fields[control.customID] = .text(limited, isEdited: true)
        clearError(control)
    }

    /// Replaces a select or checkbox-group value, keeping the order the person
    /// chose values in, which is what the request carries.
    func setSelection(_ values: [String], for control: ModalControl) {
        fields[control.customID] = .selection(values, isEdited: true)
        clearError(control)
    }

    func setEntitySelection(_ options: [ComponentSelectOption], for control: ModalControl) {
        entitySelections[control.customID] = options
        setSelection(options.map(\.value), for: control)
    }

    func toggleCheckboxGroupValue(_ value: String, for control: ModalControl) {
        guard case let .checkboxGroup(_, _, maximum) = control.kind else { return }
        var values = selectedValues(for: control)
        if let index = values.firstIndex(of: value) {
            values.remove(at: index)
        } else {
            guard values.count < maximum else { return }
            values.append(value)
        }
        setSelection(values, for: control)
    }

    func setRadio(_ value: String?, for control: ModalControl) {
        fields[control.customID] = .radio(value, isEdited: true)
        clearError(control)
    }

    func setChecked(_ value: Bool, for control: ModalControl) {
        fields[control.customID] = .checkbox(value)
        clearError(control)
    }

    func addFiles(_ urls: [URL], to control: ModalControl) {
        guard case let .fileUpload(_, maximum, fileTypes) = control.kind else { return }
        var files = files(for: control)
        var rejected: [String] = []
        for url in urls where files.count < maximum {
            guard Self.accepts(url, fileTypes: fileTypes) else {
                rejected.append(url.lastPathComponent)
                continue
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            files.append(InteractionModalFile(url: url, byteCount: size))
        }
        fields[control.customID] = .files(files)
        if rejected.isEmpty {
            clearError(control)
        } else {
            errors[control.customID] = "\(rejected.joined(separator: ", ")) isn't an allowed file type."
        }
    }

    func removeFile(_ file: InteractionModalFile, from control: ModalControl) {
        fields[control.customID] = .files(files(for: control).filter { $0.id != file.id })
        clearError(control)
    }

    private func clearError(_ control: ModalControl) {
        errors[control.customID] = nil
        formError = nil
    }

    /// Fills display labels for default entities Discord did not resolve,
    /// using what the account already has cached.
    func resolveEntityLabels(
        _ resolve: ([ComponentSelectOption], ComponentSelectKind) -> [ComponentSelectOption]
    ) {
        for control in controls {
            guard case let .select(kind, _, _, _, _, _, _) = control.kind, kind != .string,
                  let options = entitySelections[control.customID],
                  options.contains(where: { $0.label == $0.value })
            else { continue }
            let resolved = resolve(options, kind)
            entitySelections[control.customID] = zip(options, resolved).map { original, candidate in
                original.label == original.value && candidate.value == original.value ? candidate : original
            }
        }
    }

    func consumeFocusRequest() {
        focusRequest = nil
    }

    // MARK: Validation and submission

    /// Validates every control locally and focuses the first problem.
    @discardableResult
    func validate() -> Bool {
        var found: [String: String] = [:]
        for control in controls {
            if let error = validationError(for: control) {
                found[control.customID] = error
            }
        }
        errors = found
        focusRequest = controls.first { found[$0.customID] != nil }?.customID
        return found.isEmpty
    }

    func validationError(for control: ModalControl) -> String? {
        switch control.kind {
        case let .textInput(_, _, minimum, _, _):
            // Discord's server counts Unicode scalars. Catching a short value
            // here avoids a rejected request the official browser would send.
            let count = text(for: control).unicodeScalars.count
            if count == 0 {
                return control.isRequired ? "This field is required." : nil
            }
            if let minimum, count < minimum {
                return "Enter at least \(minimum) characters."
            }
            return nil
        case let .select(_, _, _, minimum, _, _, _):
            return countError(selectedValues(for: control).count, minimum: minimum, control: control)
        case let .checkboxGroup(_, minimum, _):
            return countError(selectedValues(for: control).count, minimum: minimum, control: control)
        case .radioGroup:
            return control.isRequired && radioValue(for: control) == nil
                ? "This field is required." : nil
        case let .fileUpload(minimum, _, _):
            let count = files(for: control).count
            if count == 0 {
                return control.isRequired ? "This field is required." : nil
            }
            return count < minimum ? "Upload at least \(minimum) files." : nil
        case .checkbox:
            return nil
        }
    }

    private func countError(_ count: Int, minimum: Int, control: ModalControl) -> String? {
        if count == 0 {
            return control.isRequired ? "This field is required." : nil
        }
        return count < minimum ? "Select at least \(minimum)" : nil
    }

    func submissionValues() -> [String: ModalFieldValue] {
        var values: [String: ModalFieldValue] = [:]
        for control in controls {
            switch (control.kind, fields[control.customID]) {
            case let (.textInput(_, _, _, _, initial), .text(text, isEdited)?):
                values[control.customID] = .text(isEdited ? text : initial)
            case let (.select, .selection(selected, isEdited)?),
                 let (.checkboxGroup, .selection(selected, isEdited)?):
                values[control.customID] = .values(isEdited || !selected.isEmpty ? selected : nil)
            case let (.radioGroup, .radio(value, _)?):
                values[control.customID] = .radio(value)
            case let (.checkbox, .checkbox(isChecked)?):
                values[control.customID] = .checkbox(isChecked)
            case let (.fileUpload, .files(files)?):
                values[control.customID] = .files(files.isEmpty ? nil : files.map(\.url))
            default:
                break
            }
        }
        return values
    }

    var fileURLs: [URL] {
        controls.flatMap { files(for: $0).map(\.url) }
    }

    func beginSubmitting() {
        isSubmitting = true
        formError = nil
    }

    func finishSubmitting(rejection: ModalSubmissionRejection?) {
        isSubmitting = false
        guard let rejection else { return }
        for (customID, message) in rejection.fieldMessages {
            errors[customID] = message
        }
        formError = rejection.message
        focusRequest = controls.first { rejection.fieldMessages[$0.customID] != nil }?.customID
    }

    func failSubmitting(_ message: String) {
        isSubmitting = false
        formError = message
    }

    // MARK: Helpers

    private static func initialField(for control: ModalControl) -> Field {
        switch control.kind {
        case let .textInput(_, _, _, _, initial):
            .text(initial ?? "", isEdited: false)
        case let .select(kind, _, options, _, _, _, defaults):
            .selection(
                kind == .string ? options.filter(\.isDefault).map(\.value) : defaults.map(\.id),
                isEdited: false
            )
        case let .checkboxGroup(options, _, _):
            .selection(options.filter(\.isDefault).map(\.value), isEdited: false)
        case let .radioGroup(options):
            .radio(options.first(where: \.isDefault)?.value, isEdited: false)
        case let .checkbox(isInitiallyChecked):
            .checkbox(isInitiallyChecked)
        case .fileUpload:
            .files([])
        }
    }

    private static func defaultEntityOption(
        _ value: ComponentDefaultValue,
        resolved: ModalResolvedEntities
    ) -> ComponentSelectOption {
        switch value.kind {
        case .user:
            let user = resolved.users[value.id]
            return ComponentSelectOption(
                label: user?.displayName ?? value.id, value: value.id,
                description: user.map { "@\($0.username)" }, imageURL: user?.avatarURL ?? UserID(value.id).map { User.defaultAvatarURL(id: $0) },
                imageShape: .circle, entityKind: .user
            )
        case .role:
            let role = resolved.roles[value.id]
            return ComponentSelectOption(
                label: role?.name ?? value.id, value: value.id, imageURL: role?.iconURL,
                imageShape: .roundedRectangle, entityKind: .role, colorHex: role?.colorHex,
                unicodeEmoji: role?.unicodeEmoji
            )
        case .channel:
            return ComponentSelectOption(
                label: resolved.channels[value.id]?.name ?? value.id, value: value.id,
                entityKind: .channel
            )
        }
    }

    /// Cuts text to a Unicode-scalar budget without splitting a character.
    static func truncated(_ text: String, toScalarCount limit: Int) -> String {
        guard text.unicodeScalars.count > limit else { return text }
        var result = ""
        var used = 0
        for character in text {
            let cost = character.unicodeScalars.count
            guard used + cost <= limit else { break }
            result.append(character)
            used += cost
        }
        return result
    }

    /// `fileTypes` lists extensions (".txt") or broad kinds ("image").
    static func contentTypes(for fileTypes: [String]) -> [UTType] {
        guard !fileTypes.isEmpty else { return [.item] }
        let types = fileTypes.compactMap { value -> UTType? in
            if value.hasPrefix(".") {
                return UTType(filenameExtension: String(value.dropFirst()))
            }
            return switch value.lowercased() {
            case "image": .image
            case "video": .movie
            case "audio": .audio
            case "text": .text
            default: UTType(mimeType: value)
            }
        }
        return types.isEmpty ? [.item] : types
    }

    static func accepts(_ url: URL, fileTypes: [String]) -> Bool {
        guard !fileTypes.isEmpty else { return true }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        guard let type else { return false }
        return contentTypes(for: fileTypes).contains { type.conforms(to: $0) }
    }

    static func fileTypeDescription(_ fileTypes: [String]) -> String? {
        guard !fileTypes.isEmpty else { return nil }
        return fileTypes.map { $0.hasPrefix(".") ? $0.uppercased().dropFirst().description : $0.capitalized }
            .formatted(.list(type: .or))
    }
}
