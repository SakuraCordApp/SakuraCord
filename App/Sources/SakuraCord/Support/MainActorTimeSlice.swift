import Foundation

/// Splits long main-actor work into 1.5 ms slices. Between slices it sleeps
/// rather than yields: `Task.yield()` can resume the same main-actor job
/// before the run loop services input, drawing and AppKit's display link.
struct MainActorTimeSlice {
    private var start = ProcessInfo.processInfo.systemUptime

    /// Pauses once the current slice has used its budget. False when the
    /// task is cancelled during the pause.
    mutating func pauseIfNeeded() async -> Bool {
        guard ProcessInfo.processInfo.systemUptime - start >= 0.0015 else { return true }
        do {
            try await Task.sleep(for: .milliseconds(1))
        } catch {
            return false
        }
        start = ProcessInfo.processInfo.systemUptime
        return true
    }
}
