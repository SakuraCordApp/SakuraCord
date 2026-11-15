import AppKit

/// The trackpad tick for each step of a continuous control, such as the theme
/// editor's sliders and color wheel or the schedule dialog's time.
@MainActor
enum StepHaptics {
    static func performStep() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}
