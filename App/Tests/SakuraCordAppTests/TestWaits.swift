import Observation

// Waits have no wall-clock deadline. Tests run in parallel on one main actor,
// so a test's elapsed time tracks the whole suite's and says nothing about
// the test: a loaded machine pushes every test past a per-test limit at once.
// A condition that never holds hangs instead, and the test runner's process
// deadline names the unfinished test.

/// Awaits `condition`, re-evaluating it on each observed change, which
/// catches even a brief state, and by polling, which catches state that
/// changes without an observation signal, such as counts kept out of
/// observation; false only if the caller is cancelled first.
@MainActor
func until(_ condition: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask { await firstObservation(where: condition) }
        group.addTask { await firstPoll(where: condition) }
        for await satisfied in group where satisfied {
            group.cancelAll()
            return true
        }
        return false
    }
}

@MainActor
private func firstObservation(
    where condition: @escaping @MainActor @Sendable () -> Bool
) async -> Bool {
    for await satisfied in Observations(condition) where satisfied {
        return true
    }
    return false
}

@MainActor
private func firstPoll(
    where condition: @escaping @MainActor @Sendable () -> Bool
) async -> Bool {
    await eventually { condition() }
}

/// Polls `condition` in the caller's isolation until it holds. The fallback
/// for state that emits no signal, such as actor-isolated state; false only
/// if the caller is cancelled first.
func eventually(
    isolation _: isolated (any Actor)? = #isolation,
    _ condition: () async -> Bool
) async -> Bool {
    while !(await condition()) {
        guard (try? await Task.sleep(for: .milliseconds(1))) != nil else {
            return false
        }
    }
    return true
}

/// Awaits `task`, forwarding the caller's cancellation so an unstructured
/// child cannot keep a cancelled test waiting.
func cancellableValue<Success: Sendable>(of task: Task<Success, Never>) async -> Success {
    await withTaskCancellationHandler {
        await task.value
    } onCancel: {
        task.cancel()
    }
}

/// Awaits `task`, forwarding the caller's cancellation to it.
func cancellableValue<Success: Sendable>(
    of task: Task<Success, any Error>
) async throws -> Success {
    try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}
