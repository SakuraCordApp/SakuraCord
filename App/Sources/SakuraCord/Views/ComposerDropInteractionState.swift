import Observation
import SwiftUI

@MainActor
@Observable
final class ComposerDropInteractionState {
    private(set) var destination: MessageComposerDestination?
    private(set) var isInstant = false
    /// Last time any file drop target saw the drag, read by the root view's
    /// watchdog to spot sessions that ended without an exit callback.
    @ObservationIgnored private(set) var lastDragActivity = ContinuousClock.now

    var isTargeted: Bool { destination != nil }

    func noteDragActivity() {
        lastDragActivity = .now
    }

    func update(
        isTargeted: Bool,
        destination: MessageComposerDestination,
        isInstant: Bool
    ) {
        if isTargeted { noteDragActivity() }
        self.destination = isTargeted ? destination : nil
        self.isInstant = isTargeted && isInstant
    }

    func reset() {
        // `clear(destination:)` can't cover this: a drag that ends without exiting never names its destination.
        destination = nil
        isInstant = false
    }

    func clear(destination: MessageComposerDestination) {
        guard self.destination == destination else { return }
        self.destination = nil
        isInstant = false
    }
}

extension EnvironmentValues {
    @Entry var composerDropInteraction: ComposerDropInteractionState?
}
