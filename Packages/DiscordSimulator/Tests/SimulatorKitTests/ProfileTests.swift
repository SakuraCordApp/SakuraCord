import Foundation
@testable import SimulatorKit
import Testing

struct ProfileTests {
    /// Profiles are committed and come from real accounts, so nothing in them may identify one:
    /// no snowflake-like numbers, hashes, tokens or text, only the profile's own keys.
    @Test(arguments: ["small", "medium", "medium-big-servers"])
    func bundledProfileHoldsNoIdentifiers(name: String) throws {
        let url = try AccountProfile.bundledURL(name)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.firstMatch(of: /\d{9,}/) == nil)
        #expect(text.firstMatch(of: /(?=[A-Za-z_-]*\d)(?=\d*[A-Za-z])[A-Za-z0-9_-]{8,}/) == nil)
        let keys = Set(text.matches(of: /"([^"]*)"/).map { String($0.1) })
        let profile = try AccountProfile.bundled(name)
        let encoder = JSONEncoder()
        let ownKeys = Set((String(bytes: try encoder.encode(profile), encoding: .utf8) ?? "").matches(of: /"([^"]*)"/).map { String($0.1) })
        #expect(keys.subtracting(ownKeys).isEmpty, "unexpected strings: \(keys.subtracting(ownKeys).sorted())")
        #expect(!profile.servers.isEmpty)
    }
}
