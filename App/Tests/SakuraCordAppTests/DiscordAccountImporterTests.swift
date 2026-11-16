import Foundation
@testable import SakuraCord
import Testing

struct DiscordAccountImporterTests {
    @Test func `imports only numeric account sessions and decodes Chromium strings`() throws {
        let session = "dQw4w9WgXcQ:synthetic"
        let tokens = ["123": session, "456": session, "__analytics__": session, "789": ""]
        let hash = String(repeating: "a", count: 32)
        let users: [String: Any] = ["_state": ["users": [
            ["id": "123", "username": "first", "avatar": hash],
            ["id": "456", "username": "second", "avatar": "../../invalid"]
        ]]]
        let tokenJSON = try JSONSerialization.data(withJSONObject: tokens)
        let usersJSON = try JSONSerialization.data(withJSONObject: users)
        let usersText = try #require(String(data: usersJSON, encoding: .utf8))
        let values = [
            DiscordAccountImporter.storageKey("tokens"): Data([1]) + tokenJSON,
            DiscordAccountImporter.storageKey("MultiAccountStore"): Data([0]) + (try #require(usersText.data(using: .utf16LittleEndian)))
        ]
        let accounts = try DiscordAccountImporter.decodeAccounts(values: values)
        #expect(accounts.map(\.id) == ["123", "456"])
        #expect(accounts.map(\.username) == ["first", "second"])
        #expect(accounts[0].avatarURL.absoluteString == "https://cdn.discordapp.com/avatars/123/\(hash).webp?size=128&animated=false")
        #expect(accounts[1].avatarURL.host == "discord.com")
        #expect(try DiscordAccountImporter.decodeAccounts(values: values, excluding: ["123"]).map(\.id) == ["456"])
        #expect(try DiscordAccountImporter.decodeAccounts(values: values, excluding: ["123", "456"]).isEmpty)
        #expect(throws: (any Error).self) { try DiscordAccountImporter.decodeAccounts(values: [:]) }
    }

    @Test func `decrypts Electron macOS v10 and rejects wrong keys or versions`() throws {
        // Independently produced with OpenSSL AES-128-CBC and PBKDF2-SHA1.
        let encrypted = "dQw4w9WgXcQ:djEwoICh3/wIFHYq+/qSCbMARTpjHlQHRG4E4JP6wfi10+6EvaWFnxOQRmzTqZXQODEZ"
        let password = Data("synthetic-discord-safe-storage".utf8)
        #expect(try DiscordAccountImporter.decrypt(encrypted, password: password)
            == Data("synthetic-discord-session-for-tests".utf8))
        #expect(throws: (any Error).self) {
            try DiscordAccountImporter.decrypt(encrypted, password: Data("wrong".utf8))
        }
        #expect(throws: (any Error).self) {
            try DiscordAccountImporter.decrypt("dQw4w9WgXcQ:djEx", password: password)
        }
    }

    @Test func `manifest excludes obsolete tables and latest tombstones exclude signed out accounts`() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = DiscordAccountImporter.storageKey("tokens")
        let ignored = Data("unrelated".utf8)
        try Data("MANIFEST-000001\n".utf8).write(to: directory.appending(path: "CURRENT"))
        // Active table 2, obsolete table 3, log 4. The obsolete table would
        // resurrect credentials if an importer scanned every .ldb file.
        let manifest = Data([2, 4, 7, 0, 2, 0, 0, 0])
        try Self.log(manifest).write(to: directory.appending(path: "MANIFEST-000001"))
        try Self.table(key: key, value: Data("old".utf8), sequence: 1)
            .write(to: directory.appending(path: "000002.ldb"))
        try Self.table(key: key, value: Data("obsolete".utf8), sequence: 90)
            .write(to: directory.appending(path: "000003.ldb"))
        var batch = Self.fixed(2, count: 8) + Self.fixed(2, count: 4)
        batch += Data([1]) + Self.bytes(key) + Self.bytes(Data("current".utf8))
        batch += Data([1]) + Self.bytes(ignored) + Self.bytes(Data("ignored".utf8))
        let logURL = directory.appending(path: "000004.log")
        try Self.log(batch).write(to: logURL)
        #expect(try DiscordLocalStorageReader.read(directory: directory, keys: [key]) == [key: Data("current".utf8)])
        let deletion = Self.fixed(4, count: 8) + Self.fixed(1, count: 4) + Data([0]) + Self.bytes(key)
        try (Self.log(batch) + Self.log(deletion)).write(to: logURL)
        #expect(try DiscordLocalStorageReader.read(directory: directory, keys: [key]).isEmpty)
        var corrupt = Self.log(batch)
        corrupt[0] ^= 1
        try corrupt.write(to: logURL)
        #expect(throws: (any Error).self) { try DiscordLocalStorageReader.read(directory: directory, keys: [key]) }
    }

    @Test func `fragmented log and Snappy copies are bounded and checked`() throws {
        let first = Data(repeating: 65, count: 32761)
        let last = Data("tail".utf8)
        #expect(try DiscordLocalStorageReader.logRecords(Self.log(first, kind: 2) + Self.log(last, kind: 4)) == [first + last])
        #expect(throws: (any Error).self) { try DiscordLocalStorageReader.logRecords(Self.log(first, kind: 2)) }
        #expect(try DiscordLocalStorageReader.uncompressSnappy(Data([8, 4, 97, 98, 22, 2, 0])) == Data("abababab".utf8))
        #expect(throws: (any Error).self) { try DiscordLocalStorageReader.uncompressSnappy(Data([8, 1, 0])) }
        #expect(throws: (any Error).self) { try DiscordLocalStorageReader.uncompressSnappy(Data([1, 4, 97, 98])) }
    }

    private static func fixed(_ value: UInt64, count: Int) -> Data {
        Data((0 ..< count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    private static func varint(_ value: UInt64) -> Data {
        var value = value
        var output = Data()
        while value >= 128 {
            output.append(UInt8(value & 127) | 128)
            value >>= 7
        }
        output.append(UInt8(value))
        return output
    }

    private static func bytes(_ data: Data) -> Data { varint(UInt64(data.count)) + data }

    private static func log(_ data: Data, kind: UInt8 = 1) -> Data {
        fixed(UInt64(DiscordLocalStorageReader.maskedChecksum(Data([kind]) + data)), count: 4)
            + fixed(UInt64(data.count), count: 2) + Data([kind]) + data
    }

    private static func table(key: Data, value: Data, sequence: UInt64) -> Data {
        func block(_ key: Data, _ value: Data) -> Data {
            let raw = Data([0]) + varint(UInt64(key.count)) + varint(UInt64(value.count)) + key + value
                + fixed(0, count: 4) + fixed(1, count: 4)
            return raw + Data([0]) + fixed(UInt64(DiscordLocalStorageReader.maskedChecksum(raw + Data([0]))), count: 4)
        }
        let dataBlock = block(key + fixed(sequence << 8 | 1, count: 8), value)
        let indexBlock = block(key + fixed(sequence << 8 | 1, count: 8), Data([0]) + varint(UInt64(dataBlock.count - 5)))
        var footer = Data([0, 0]) + varint(UInt64(dataBlock.count)) + varint(UInt64(indexBlock.count - 5))
        footer.append(Data(repeating: 0, count: 40 - footer.count))
        footer.append(fixed(0xdb47_7524_8b80_fb57, count: 8))
        return dataBlock + indexBlock + footer
    }
}
