import Foundation
@testable import SimulatorKit
import Testing

struct ProfileTests {
    /// Profiles are committed and come from real accounts, so nothing in them may identify one:
    /// no snowflake-like numbers, hashes, tokens or text, only the profile's own keys. Every
    /// bundled profile is checked, so a newly extracted one can't slip through.
    @Test func bundledProfilesHoldNoIdentifiers() throws {
        let directory = try AccountProfile.bundledURL("medium").deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count >= 3)
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.firstMatch(of: /\d{9,}/) == nil, "\(url.lastPathComponent)")
            #expect(text.firstMatch(of: /(?=[A-Za-z_-]*\d)(?=\d*[A-Za-z])[A-Za-z0-9_-]{8,}/) == nil, "\(url.lastPathComponent)")
            let profile = try JSONDecoder().decode(AccountProfile.self, from: Data(contentsOf: url))
            let ownKeys = Set((String(bytes: try JSONEncoder().encode(profile), encoding: .utf8) ?? "").matches(of: /"([^"]*)"/).map { String($0.1) })
            let unexpected = Set(text.matches(of: /"([^"]*)"/).map { String($0.1) }).subtracting(ownKeys)
            #expect(unexpected.isEmpty, "\(url.lastPathComponent): unexpected strings \(unexpected.sorted())")
            #expect(!profile.servers.isEmpty)
        }
    }
}
