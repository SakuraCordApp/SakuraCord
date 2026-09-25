import SwiftUI

/// Shows the original draft above a translated one, and translation progress
/// or errors, in the composer header.
struct ComposerTranslationHeader: View {
    let model: AppModel
    let destination: MessageComposerDestination

    var body: some View {
        if let state = model.draftTranslation(for: destination) {
            VStack(alignment: .leading, spacing: 0) {
                content(for: state)
                    .font(.callout)
                    .padding(.leading, 12)
                    .padding(.trailing, 8)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(background(for: state.phase))
                Divider()
            }
        }
    }

    @ViewBuilder
    private func content(for state: DraftTranslation) -> some View {
        switch state.phase {
        case .translating:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Translating to \(TranslationLanguage(id: state.language).displayName())…")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                closeButton(help: "Cancel translation")
            }
        case .translated:
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Original")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(state.original)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 100)
                    Text("Translated to \(TranslationLanguage(id: state.language).displayName())")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SakuraCordAccentColor.color)
                }
                .padding(.vertical, 4)
                Spacer(minLength: 8)
                Button("Show Original") { model.showOriginalDraft(in: destination) }
                    .buttonStyle(.borderless)
                    .padding(.top, 6)
                closeButton(help: "Keep translation")
            }
        case .showingOriginal:
            HStack(spacing: 8) {
                Image(systemName: "translate")
                    .foregroundStyle(.secondary)
                Text("Showing original")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Show Translation") { model.translateDraft(in: destination) }
                    .buttonStyle(.borderless)
                closeButton(help: "Discard translation")
            }
        case let .failed(message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .lineLimit(2)
                Spacer(minLength: 8)
                closeButton(help: "Dismiss error")
            }
        }
    }

    private func closeButton(help: LocalizedStringResource) -> some View {
        HoverCloseButton(
            help: help,
            accessibilityIdentifier: "composer-translation-close",
            diameter: 30,
            iconSize: 13
        ) {
            model.dismissDraftTranslation(in: destination)
        }
    }

    private func background(for phase: DraftTranslation.Phase) -> AnyShapeStyle {
        if case .failed = phase { return AnyShapeStyle(Color.red.opacity(0.08)) }
        return AnyShapeStyle(.primary.opacity(0.035))
    }
}

/// The "Translate Draft" row in the composer's + menu.
struct ComposerTranslateDraftRow: View {
    let model: AppModel
    let destination: MessageComposerDestination
    let dismiss: () -> Void

    var body: some View {
        if model.translation.settings.isEnabled {
            let isTranslated = model.draftTranslation(for: destination)?.phase == .translated
            Button {
                dismiss()
                model.translateDraft(in: destination)
            } label: {
                Label(isTranslated ? "Show Original" : "Translate Draft", systemImage: "translate")
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .disabled(!model.canTranslateDraft(in: destination))
        }
    }
}
