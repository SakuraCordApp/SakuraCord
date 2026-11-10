import Darwin
@testable import DiscordProtocol
import Foundation
@testable import SakuraCord
import SakuraCordModels
import Testing

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

    @Test func `server starts and accepts handshake responding with ready event`() throws {
        let socketPath = makeTestSocketPath()
        let mockProvider = MockChatProvider()
        let coordinator = ActivityCoordinator(provider: mockProvider, preferences: .enabledAll)
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
        let coordinator = ActivityCoordinator(provider: mockProvider, preferences: .enabledAll)
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

        // Wait for coordinator to synchronize activity
        let updated = await eventually {
            (await mockProvider.currentActivities()).count == 1
        }
        #expect(updated)
        let activities = await mockProvider.currentActivities()
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

        let cleared = await eventually {
            (await mockProvider.currentActivities()).isEmpty
        }
        #expect(cleared)
    }

    @Test func `disconnecting client automatically clears its activity`() async throws {
        let socketPath = makeTestSocketPath()
        let mockProvider = MockChatProvider()
        let coordinator = ActivityCoordinator(provider: mockProvider, preferences: .enabledAll)
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

        let published = await eventually {
            (await mockProvider.currentActivities()).count == 1
        }
        #expect(published)

        // Close client socket abruptly
        close(clientFD)

        let cleared = await eventually {
            (await mockProvider.currentActivities()).isEmpty
        }
        #expect(cleared)
    }

    @Test func `ping frame receives pong response`() throws {
        let socketPath = makeTestSocketPath()
        let mockProvider = MockChatProvider()
        let coordinator = ActivityCoordinator(provider: mockProvider, preferences: .enabledAll)
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

    @Test func `large PID does not crash server and SET_ACTIVITY succeeds`() throws {
        let socketPath = makeTestSocketPath()
        let mockProvider = MockChatProvider()
        let coordinator = ActivityCoordinator(provider: mockProvider, preferences: .enabledAll)
        let server = DiscordIPCServer(coordinator: coordinator, socketPath: socketPath)
        try server.start()
        defer { server.stop() }

        let clientFD = try #require(connectClient(to: socketPath))
        defer { close(clientFD) }

        sendClientFrame(fd: clientFD, opcode: 0, jsonObject: ["v": 1, "client_id": "app_large_pid"])
        _ = try #require(readClientFrame(fd: clientFD))

        // Send pid larger than Int32.max (2147483648)
        sendClientFrame(fd: clientFD, opcode: 1, jsonObject: [
            "cmd": "SET_ACTIVITY",
            "args": [
                "pid": 2_147_483_648 as Int,
                "activity": ["name": "SafeApp"],
            ],
            "nonce": "n-safe",
        ])

        let res = try #require(readClientFrame(fd: clientFD))
        #expect(res.opcode == 1)
        #expect(res.json["cmd"] as? String == "SET_ACTIVITY")
        #expect(res.json["nonce"] as? String == "n-safe")
    }

    @Test func `oversized frame disconnects client without crashing`() async throws {
        let socketPath = makeTestSocketPath()
        let mockProvider = MockChatProvider()
        let coordinator = ActivityCoordinator(provider: mockProvider, preferences: .enabledAll)
        let server = DiscordIPCServer(coordinator: coordinator, socketPath: socketPath)
        try server.start()
        defer { server.stop() }

        let clientFD = try #require(connectClient(to: socketPath))
        defer { close(clientFD) }

        // Send a frame with length field declared as 2 MB (> 1 MB limit)
        var data = Data()
        var op = UInt32(1).littleEndian
        var len = UInt32(2 * 1024 * 1024).littleEndian
        withUnsafeBytes(of: &op) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &len) { data.append(contentsOf: $0) }
        _ = data.withUnsafeBytes { ptr in
            Darwin.write(clientFD, ptr.baseAddress!, data.count)
        }

        // Connection should be closed by server
        let disconnected = await eventually {
            var buf = [UInt8](repeating: 0, count: 16)
            let n = Darwin.read(clientFD, &buf, buf.count)
            return n <= 0
        }
        #expect(disconnected)
    }

    @Test func `SET_ACTIVITY timestamps in seconds are converted to milliseconds`() async throws {
        let socketPath = makeTestSocketPath()
        let mockProvider = MockChatProvider()
        let coordinator = ActivityCoordinator(provider: mockProvider, preferences: .enabledAll)
        let server = DiscordIPCServer(coordinator: coordinator, socketPath: socketPath)
        try server.start()
        defer { server.stop() }

        let clientFD = try #require(connectClient(to: socketPath))
        defer { close(clientFD) }

        sendClientFrame(fd: clientFD, opcode: 0, jsonObject: ["v": 1, "client_id": "craftpresence_app"])
        _ = try #require(readClientFrame(fd: clientFD))

        let startSeconds: Int64 = 1_700_000_000
        let activityDict: [String: Any] = [
            "name": "Minecraft",
            "details": "In Menus",
            "type": 0,
            "timestamps": [
                "start": startSeconds,
            ],
        ]
        sendClientFrame(fd: clientFD, opcode: 1, jsonObject: [
            "cmd": "SET_ACTIVITY",
            "args": ["activity": activityDict],
            "nonce": "ts-test",
        ])
        _ = try #require(readClientFrame(fd: clientFD))

        let updated = await eventually {
            (await mockProvider.currentActivities()).count == 1
        }
        #expect(updated)
        let activities = await mockProvider.currentActivities()
        let published = try #require(activities.values.first)
        #expect(published.timestamps?.start == startSeconds * 1000)
    }

    private func createListeningSocket(at path: String) -> Int32? {
        let listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(listenFD)
            return nil
        }
        withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            _ = pathBytes.withUnsafeBufferPointer { buf in
                memcpy(ptr, buf.baseAddress!, buf.count)
            }
        }
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddrPtr in
                Darwin.bind(listenFD, sockAddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(listenFD, 5) == 0 else {
            close(listenFD)
            return nil
        }
        return listenFD
    }

    private func createDeadSocket(at path: String) {
        let deadFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard deadFD >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(deadFD)
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            _ = pathBytes.withUnsafeBufferPointer { buf in
                memcpy(ptr, buf.baseAddress!, buf.count)
            }
        }
        _ = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddrPtr in
                Darwin.bind(deadFD, sockAddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(deadFD)
    }

    @Test func `purgeStaleSockets removes dead sockets and broken symlinks but preserves active ones`() throws {
        let tempDir = "/tmp/test-ipc-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let activeSocketPath = "\(tempDir)/discord-ipc-0"
        let activeFD = try #require(createListeningSocket(at: activeSocketPath))
        defer {
            close(activeFD)
            unlink(activeSocketPath)
        }

        let deadSocketPath = "\(tempDir)/discord-ipc-1"
        createDeadSocket(at: deadSocketPath)

        let brokenSymlinkPath = "\(tempDir)/discord-ipc-2"
        symlink("\(tempDir)/nonexistent-target", brokenSymlinkPath)

        let activeSymlinkPath = "\(tempDir)/discord-ipc-3"
        symlink(activeSocketPath, activeSymlinkPath)
        defer { unlink(activeSymlinkPath) }

        DiscordIPCServer.purgeStaleSockets(in: tempDir)

        #expect(FileManager.default.fileExists(atPath: activeSocketPath))
        #expect(!FileManager.default.fileExists(atPath: deadSocketPath))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: brokenSymlinkPath)) == nil)
        #expect(FileManager.default.fileExists(atPath: activeSymlinkPath))
    }

    @Test func `canReplaceWithSymlink preserves active sockets and symlinks but permits stale replacement`() throws {
        let tempDir = "/tmp/test-ipc-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        // Non-existent path can be replaced
        let freePath = "\(tempDir)/free.sock"
        #expect(DiscordIPCServer.probeSocketListener(at: freePath) == .stale)
        #expect(DiscordIPCServer.canReplaceWithSymlink(at: freePath))

        // Active socket cannot be replaced
        let activeSocketPath = "\(tempDir)/active.sock"
        let activeFD = try #require(createListeningSocket(at: activeSocketPath))
        defer {
            close(activeFD)
            unlink(activeSocketPath)
        }
        #expect(DiscordIPCServer.probeSocketListener(at: activeSocketPath) == .active)
        #expect(!DiscordIPCServer.canReplaceWithSymlink(at: activeSocketPath))
        #expect(FileManager.default.fileExists(atPath: activeSocketPath))

        // Symlink pointing to active socket cannot be replaced
        let symlinkToActive = "\(tempDir)/symlink_active.sock"
        symlink(activeSocketPath, symlinkToActive)
        defer { unlink(symlinkToActive) }
        #expect(!DiscordIPCServer.canReplaceWithSymlink(at: symlinkToActive))
        #expect(FileManager.default.fileExists(atPath: symlinkToActive))

        // Dead socket can be replaced and gets unlinked
        let deadSocketPath = "\(tempDir)/dead.sock"
        createDeadSocket(at: deadSocketPath)
        #expect(DiscordIPCServer.probeSocketListener(at: deadSocketPath) == .stale)
        #expect(DiscordIPCServer.canReplaceWithSymlink(at: deadSocketPath))
        #expect(!FileManager.default.fileExists(atPath: deadSocketPath))

        // Broken symlink can be replaced and gets unlinked
        let brokenSymlink = "\(tempDir)/broken_symlink.sock"
        symlink("\(tempDir)/nonexistent", brokenSymlink)
        #expect(DiscordIPCServer.canReplaceWithSymlink(at: brokenSymlink))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: brokenSymlink)) == nil)
    }

    @Test func `removeSymlinkIfOwned removes symlink only if destination matches target socket`() throws {
        let tempDir = "/tmp/test-ipc-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let targetSocketPath = "\(tempDir)/our_server.sock"
        let otherSocketPath = "\(tempDir)/other_server.sock"
        let symlinkPath = "\(tempDir)/discord-ipc-0"

        // Points to our target -> removed
        symlink(targetSocketPath, symlinkPath)
        DiscordIPCServer.removeSymlinkIfOwned(symlinkPath: symlinkPath, targetPath: targetSocketPath)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: symlinkPath)) == nil)

        // Points to other target -> NOT removed
        symlink(otherSocketPath, symlinkPath)
        DiscordIPCServer.removeSymlinkIfOwned(symlinkPath: symlinkPath, targetPath: targetSocketPath)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: symlinkPath)) == otherSocketPath)
        unlink(symlinkPath)

        // Non-symlink file -> NOT removed
        FileManager.default.createFile(atPath: symlinkPath, contents: Data())
        DiscordIPCServer.removeSymlinkIfOwned(symlinkPath: symlinkPath, targetPath: targetSocketPath)
        #expect(FileManager.default.fileExists(atPath: symlinkPath))
        unlink(symlinkPath)
    }

    @Test func `server accepts numeric client id and responds to authenticate command`() async throws {
        let socketPath = makeTestSocketPath()
        let mockProvider = MockChatProvider()
        let coordinator = ActivityCoordinator(provider: mockProvider, preferences: .enabledAll)
        let server = DiscordIPCServer(coordinator: coordinator, socketPath: socketPath)
        try server.start()
        defer { server.stop() }

        let clientFD = try #require(connectClient(to: socketPath))
        defer { close(clientFD) }

        // Send numeric snowflake client_id (used by Roblox RPC and Discord GameSDK)
        sendClientFrame(fd: clientFD, opcode: 0, jsonObject: ["v": 1, "client_id": 1004128076435017778 as NSNumber])
        let readyResponse = try #require(readClientFrame(fd: clientFD))
        #expect(readyResponse.opcode == 1)
        #expect(readyResponse.json["cmd"] as? String == "DISPATCH")
        #expect(readyResponse.json["evt"] as? String == "READY")

        // Send AUTHENTICATE command
        sendClientFrame(fd: clientFD, opcode: 1, jsonObject: [
            "cmd": "AUTHENTICATE",
            "args": ["access_token": "dummy_token"],
            "nonce": "auth-nonce-1"
        ])
        let authResponse = try #require(readClientFrame(fd: clientFD))
        #expect(authResponse.opcode == 1)
        #expect(authResponse.json["cmd"] as? String == "AUTHENTICATE")
        #expect(authResponse.json["nonce"] as? String == "auth-nonce-1")
        #expect(authResponse.json["data"] is [String: Any])

        // Set activity without explicit name but with large_text -> resolves name from large_text
        sendClientFrame(fd: clientFD, opcode: 1, jsonObject: [
            "cmd": "SET_ACTIVITY",
            "args": [
                "pid": 54321,
                "activity": [
                    "details": "Playing Murder Mystery 2",
                    "state": "In Game",
                    "assets": [
                        "large_image": "roblox_icon",
                        "large_text": "Roblox"
                    ]
                ]
            ],
            "nonce": "act-nonce-1"
        ])

        try await Task.sleep(nanoseconds: 100_000_000)
        let primary = await coordinator.currentPrimaryActivity()
        #expect(primary?.name == "Roblox")
        #expect(primary?.details == "Playing Murder Mystery 2")
        #expect(primary?.state == "In Game")
    }
}
