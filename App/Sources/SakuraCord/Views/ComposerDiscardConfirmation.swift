import SwiftUI

enum ComposerDiscardRequest {
    case attachments
    case command

    var message: String {
        switch self {
        case .attachments:
            "The unsent attachments will be removed. Your saved message draft is kept."
        case .command:
            "The values entered for this command will be discarded."
        }
    }
}

extension View {
    func composerDiscardConfirmation(
        request: Binding<ComposerDiscardRequest?>,
        discard: @escaping () -> Void
    ) -> some View {
        confirmationDialog(
            "Discard Composer Changes?",
            isPresented: Binding(
                get: { request.wrappedValue != nil },
                set: { isPresented in
                    if !isPresented {
                        request.wrappedValue = nil
                    }
                }
            )
        ) {
            Button("Discard", role: .destructive, action: discard)
            Button("Cancel", role: .cancel) {
                request.wrappedValue = nil
            }
        } message: {
            Text(request.wrappedValue?.message ?? "")
        }
    }
}
