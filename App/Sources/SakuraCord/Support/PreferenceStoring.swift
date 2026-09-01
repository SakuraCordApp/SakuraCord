import Foundation

nonisolated protocol PreferenceStoring: Sendable {
    func object(forKey defaultName: String) -> Any?
    func string(forKey defaultName: String) -> String?
    func data(forKey defaultName: String) -> Data?
    func bool(forKey defaultName: String) -> Bool
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: PreferenceStoring {}
