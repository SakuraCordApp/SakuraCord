import SwiftUI
import Translation

/// Lives at the main window root, independently of recycled rows and menus.
struct TranslationTaskHost: ViewModifier {
    let coordinator: AppleTranslationCoordinator
    @State private var hostID = UUID()

    func body(content: Content) -> some View {
        content
            .background {
                if let operation = coordinator.active {
                    TranslationOperationHost(coordinator: coordinator, operation: operation)
                        .id(operation.id)
                }
            }
            .onAppear { coordinator.attachHost(hostID) }
            .onDisappear { coordinator.detachHost(hostID) }
    }
}

private struct TranslationOperationHost: View {
    let coordinator: AppleTranslationCoordinator
    let operation: AppleTranslationCoordinator.Operation

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .task(id: operation.id) { await coordinator.prepare(operation) }
            .translationTask(operation.target.map { target in
                TranslationSession.Configuration(
                    source: nil, target: Locale.Language(identifier: target.id), preferredStrategy: .highFidelity
                )
            }) { @Sendable session in
                await coordinator.perform(operation, using: AppleTranslationSessionClient(session: session))
            }
            .onDisappear {
                coordinator.finish(operation.id, with: .failure(CancellationError()))
            }
    }
}
