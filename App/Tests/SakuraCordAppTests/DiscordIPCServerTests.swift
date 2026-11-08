import Darwin
@testable import DiscordProtocol
import Foundation
@testable import SakuraCord
import SakuraCordModels
import Testing

@Suite
struct DiscordIPCServerTests {
    private func makeTestSocketPath() -> String {
        "/tmp/sakuracord-ipc-test-\(UUID().uuidString).sock"
    }

    private func connectClient(to socketPath: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            _ = pathBytes.withUnsafeBufferPointer { buf in
                memcpy(ptr, buf.baseAddress!, buf.count)
            }
        }
        let res = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddrPtr in
                Darwin.connect(fd, sockAddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard res == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    private func sendClientFrame(fd: Int32, opcode: UInt32, jsonObject: Any) {
        guard let json = try? JSONSerialization.data(withJSONObject: jsonObject) else { return }
        var data = Data()
        var op = opcode.littleEndian
        var len = UInt32(json.count).littleEndian
        withUnsafeBytes(of: &op) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &len) { data.append(contentsOf: $0) }
        data.append(json)
        _ = data.withUnsafeBytes { ptr in
            Darwin.write(fd, ptr.baseAddress!, data.count)
        }
    }

    private func readClientFrame(fd: Int32) -> (opcode: UInt32, json: [String: Any])? {
        var header = [UInt8](repeating: 0, count: 8)
        var headerRead = 0
        while headerRead < 8 {
            let n = Darwin.read(fd, &header[headerRead], 8 - headerRead)
            if n <= 0 { return nil }
            headerRead += n
        }
        let op = header.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
        let len = header.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
        let opcode = UInt32(littleEndian: op)
        let length = Int(UInt32(littleEndian: len))

        var payload = [UInt8](repeating: 0, count: length)
        var payloadRead = 0
        while payloadRead < length {
            let n = Darwin.read(fd, &payload[payloadRead], length - payloadRead)
            if n <= 0 { return nil }
            payloadRead += n
        }
        guard let json = try? JSONSerialization.jsonObject(with: Data(payload)) as? [String: Any] else {
            return nil
        }
        return (opcode, json)
    }

    @Test func `candidate socket paths return discord-ipc-0 through 9`() {
        let paths = DiscordIPCServer.candidateSocketPaths()
        #expect(paths.count == 10)
        #expect(paths.first?.hasSuffix("discord-ipc-0") == true)
        #expect(paths.last?.hasSuffix("discord-ipc-9") == true)
    }

    @Test func `server starts and accepts handshake responding with ready event`() async throws {
        let socketPath = makeTestSocketPath()
        let mockProvider = MockChatProvider()
        let coordinator = ActivityCoordinator(provider: mockProvider)
        let server = DiscordIPCServer(coordinator: coordinator, socketPath: socketPath)
        try server.start()
        defer { server.stop() }

        #expect(server.isServerRunning)
        #expect(server.currentBoundSocketPath == socketPath)

        let clientFD = try #require(connectClient(to: socketPath))
        defer { close(clientFD) }

        // Send Opcode 0 (HANDSHAKE)
        sendClientFrame(fd: clientFD, opcode: 0, jsonObject: ["v": 1, "client_id": "test_app_123"])

        // Expect Opcode 1 (FRAME) with READY event
        let response = try #require(readClientFrame(fd: clientFD))
        #expect(response.opcode == 1)
        #expect(response.json["cmd"] as? String == "DISPATCH")
        #expect(response.json["evt"] as? String == "READY")
    }

    @Test func `client can set and clear activity through IPC`() async throws {
        let socketPath = makeTestSocketPath()
        let mockProvider = MockChatProvider()
        let coordinator = ActivityCoordinator(provider: mockProvider)
        let server = DiscordIPCServer(coordinator: coordinator, socketPath: socketPath)
        try server.start()
        defer { server.stop() }

        let clientFD = try #require(connectClient(to: socketPath))
        defer { close(clientFD) }

        // Handshake
        sendClientFrame(fd: clientFD, opcode: 0, jsonObject: ["v": 1, "client_id": "modrinth_app"])
        _ = try #require(readClientFrame(fd: clientFD))

        // Set Activity
        let activityDict: [String: Any] = [
            "name": "Minecraft",
            "details": "Playing Fabric 1.20.4",
            "state": "In Singleplayer",
            "type": 0,
        ]
        sendClientFrame(fd: clientFD, opcode: 1, jsonObject: [
            "cmd": "SET_ACTIVITY",
            "args": [
                "pid": 4242,
                "activity": activityDict,
            ],
            "nonce": "test-nonce-1",
        ])

        let setResponse = try #require(readClientFrame(fd: clientFD))
        #expect(setResponse.opcode == 1)
        #expect(setResponse.json["cmd"] as? String == "SET_ACTIVITY")
        #expect(setResponse.json["nonce"] as? String == "test-nonce-1")

        // Wait briefly for coordinator to update
        try await Task.sleep(for: .milliseconds(50))
        let activities = await mockProvider.currentActivities()
        #expect(activities.count == 1)
        let published = try #require(activities.values.first)
        #expect(published.name == "Minecraft")
        #expect(published.details == "Playing Fabric 1.20.4")
        #expect(published.state == "In Singleplayer")

        // Clear Activity
        sendClientFrame(fd: clientFD, opcode: 1, jsonObject: [
            "cmd": "SET_ACTIVITY",
            "args": [
                "pid": 4242,
            ],
            "nonce": "test-nonce-2",
        ])

        let clearResponse = try #require(readClientFrame(fd: clientFD))
        #expect(clearResponse.opcode == 1)
        #expect(clearResponse.json["cmd"] as? String == "SET_ACTIVITY")

        try await Task.sleep(for: .milliseconds(50))
        #expect(await mockProvider.currentActivities().isEmpty)
    }

    @Test func `disconnecting client automatically clears its activity`() async throws {
        let socketPath = makeTestSocketPath()
        let mockProvider = MockChatProvider()
        let coordinator = ActivityCoordinator(provider: mockProvider)
        let server = DiscordIPCServer(coordinator: coordinator, socketPath: socketPath)
        try server.start()
        defer { server.stop() }

        let clientFD = try #require(connectClient(to: socketPath))

        sendClientFrame(fd: clientFD, opcode: 0, jsonObject: ["v": 1, "client_id": "game_app"])
        _ = try #require(readClientFrame(fd: clientFD))

        sendClientFrame(fd: clientFD, opcode: 1, jsonObject: [
            "cmd": "SET_ACTIVITY",
            "args": [
                "activity": ["name": "Sonora Player", "details": "Listening to Jazz"],
            ],
            "nonce": "n1",
        ])
        _ = try #require(readClientFrame(fd: clientFD))

        try await Task.sleep(for: .milliseconds(50))
        #expect(await mockProvider.currentActivities().count == 1)

        // Close client socket abruptly
        close(clientFD)

        try await Task.sleep(for: .milliseconds(100))
        #expect(await mockProvider.currentActivities().isEmpty)
    }

    @Test func `ping frame receives pong response`() async throws {
        let socketPath = makeTestSocketPath()
        let mockProvider = MockChatProvider()
        let coordinator = ActivityCoordinator(provider: mockProvider)
        let server = DiscordIPCServer(coordinator: coordinator, socketPath: socketPath)
        try server.start()
        defer { server.stop() }

        let clientFD = try #require(connectClient(to: socketPath))
        defer { close(clientFD) }

        sendClientFrame(fd: clientFD, opcode: 3, jsonObject: ["ping": "hello"])
        let pong = try #require(readClientFrame(fd: clientFD))
        #expect(pong.opcode == 4)
        #expect(pong.json["ping"] as? String == "hello")
    }
}
