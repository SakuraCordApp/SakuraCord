@testable import SakuraCord
import Foundation
import Synchronization

nonisolated final class InMemoryPreferences: PreferenceStoring, Sendable {
    private struct StoredValue: @unchecked Sendable {
        let value: Any
    }

    private let values = Mutex<[String: StoredValue]>([:])

    func object(forKey defaultName: String) -> Any? {
        values.withLock { $0[defaultName]?.value }
    }

    func string(forKey defaultName: String) -> String? {
        object(forKey: defaultName) as? String
    }

    func data(forKey defaultName: String) -> Data? {
        object(forKey: defaultName) as? Data
    }

    func bool(forKey defaultName: String) -> Bool {
        object(forKey: defaultName) as? Bool ?? false
    }

    func set(_ value: Any?, forKey defaultName: String) {
        if let value {
            let storedValue = StoredValue(value: value)
            values.withLock { $0[defaultName] = storedValue }
        } else {
            removeObject(forKey: defaultName)
        }
    }

    func removeObject(forKey defaultName: String) {
        values.withLock { _ = $0.removeValue(forKey: defaultName) }
    }
}
