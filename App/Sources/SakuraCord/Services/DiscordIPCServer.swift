import Darwin
import DiscordProtocol
import Foundation
import os
import SakuraCordModels

private extension Data {
    nonisolated func readUInt32LittleEndian(at offset: Int) -> UInt32? {
        guard count >= offset + 4 else { return nil }
        let b0 = UInt32(self[offset])
        let b1 = UInt32(self[offset + 1])
        let b2 = UInt32(self[offset + 2])
        let b3 = UInt32(self[offset + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    nonisolated mutating func appendUInt32LittleEndian(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}

nonisolated final class DiscordIPCClientSession: @unchecked Sendable {
    let id = UUID()
    let clientFD: Int32
    let coordinator: ActivityCoordinator
    var clientID: String?
    var processID: pid_t?
    private var readBuffer = Data()
    private var readSource: DispatchSourceRead?
    private let queue: DispatchQueue
    private let onClose: @Sendable (UUID) -> Void
    private let logger = Logger(subsystem: "dev.sakuracord", category: "DiscordIPCClientSession")

    init(
        clientFD: Int32,
        coordinator: ActivityCoordinator,
        queue: DispatchQueue,
        onClose: @escaping @Sendable (UUID) -> Void
    ) {
        self.clientFD = clientFD
        self.coordinator = coordinator
        self.queue = queue
        self.onClose = onClose
    }

    deinit {
        stop()
    }

    func start() {
        let fd = clientFD
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.handleRead()
        }
        source.setCancelHandler {
            close(fd)
        }
        self.readSource = source
        source.resume()
    }

    func stop() {
        guard readSource != nil else { return }
        readSource?.cancel()
        readSource = nil
        let source = ActivitySource.localRPC(
            sourceID: id.uuidString,
            clientID: clientID ?? "unknown",
            processID: processID
        )
        Task { [coordinator] in
            await coordinator.clearActivity(for: source)
        }
        onClose(id)
    }

    private func handleRead() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(clientFD, &buffer, buffer.count)
        if bytesRead <= 0 {
            stop()
            return
        }
        readBuffer.append(buffer, count: bytesRead)
        processIncomingFrames()
    }

    private func processIncomingFrames() {
        while readBuffer.count >= 8 {
            guard let opcode = readBuffer.readUInt32LittleEndian(at: 0),
                  let length = readBuffer.readUInt32LittleEndian(at: 4) else {
                break
            }
            if length > DiscordIPCServer.maxFramePayloadSize {
                logger.warning("Incoming IPC frame length \(length) exceeds maximum allowed size \(DiscordIPCServer.maxFramePayloadSize); closing session.")
                stop()
                return
            }
            let totalFrameSize = 8 + Int(length)
            guard readBuffer.count >= totalFrameSize else {
                if readBuffer.count > DiscordIPCServer.maxFramePayloadSize * 2 {
                    logger.warning("Read buffer size \(self.readBuffer.count) exceeded safety limit; closing session.")
                    stop()
                }
                break
            }
            let payloadData = readBuffer.subdata(in: 8 ..< totalFrameSize)
            readBuffer.removeSubrange(0 ..< totalFrameSize)
            handleFrame(opcode: opcode, payloadData: payloadData)
        }
    }

    private func handleFrame(opcode: UInt32, payloadData: Data) {
        switch opcode {
        case 0: // HANDSHAKE
            guard let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
                stop()
                return
            }
            let clientID: String
            if let str = json["client_id"] as? String {
                clientID = str
            } else if let num = json["client_id"] as? NSNumber {
                clientID = num.stringValue
            } else {
                stop()
                return
            }
            self.clientID = clientID
            sendReadyEvent(clientID: clientID)

        case 1: // FRAME
            guard let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
                  let cmd = json["cmd"] as? String else {
                return
            }
            let nonce = json["nonce"] as? String
            let args = json["args"] as? [String: Any] ?? [:]
            handleCommand(cmd: cmd, args: args, nonce: nonce)

        case 2: // CLOSE
            stop()

        case 3: // PING
            sendFrame(opcode: 4, jsonObject: (try? JSONSerialization.jsonObject(with: payloadData)) ?? [:])

        default:
            break
        }
    }

    private func handleCommand(cmd: String, args: [String: Any], nonce: String?) {
        switch cmd {
        case "SET_ACTIVITY":
            if let pid = args["pid"] as? Int, let validPid = pid_t(exactly: pid), validPid > 0 {
                self.processID = validPid
            }
            let activityDict = args["activity"] as? [String: Any]
            let source = ActivitySource.localRPC(
                sourceID: id.uuidString,
                clientID: clientID ?? "unknown",
                processID: processID
            )

            if let activityDict {
                let payload = parseActivity(activityDict)
                Task { [coordinator] in
                    await coordinator.setActivity(payload, for: source)
                }
                sendResponse(cmd: "SET_ACTIVITY", data: activityDict, nonce: nonce)
            } else {
                Task { [coordinator] in
                    await coordinator.clearActivity(for: source)
                }
                sendResponse(cmd: "SET_ACTIVITY", data: NSNull(), nonce: nonce)
            }

        case "SUBSCRIBE", "UNSUBSCRIBE":
            let evt = args["evt"] as? String ?? ""
            sendResponse(cmd: cmd, data: ["evt": evt], nonce: nonce)

        case "AUTHENTICATE", "AUTHORIZE":
            let data: [String: Any] = [
                "application": ["id": clientID ?? "1", "name": "SakuraCord"],
                "user": [
                    "id": "1",
                    "username": "SakuraCord",
                    "discriminator": "0000",
                    "avatar": NSNull(),
                ],
                "scopes": ["rpc", "identify"],
                "expires": "2099-01-01T00:00:00.000Z",
            ]
            sendResponse(cmd: cmd, data: data, nonce: nonce)

        default:
            sendResponse(cmd: cmd, data: NSNull(), nonce: nonce)
        }
    }

    private func parseActivity(_ dict: [String: Any]) -> OutgoingActivityPayload {
        let assetsDict = dict["assets"] as? [String: Any]
        let rawName = (dict["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let largeText = (assetsDict?["large_text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String = {
            if let rawName, !rawName.isEmpty, rawName != clientID {
                return rawName
            }
            if let largeText, !largeText.isEmpty, !largeText.lowercased().hasPrefix("http") {
                return largeText
            }
            if let rawName, !rawName.isEmpty {
                return rawName
            }
            if let clientID, !clientID.isEmpty, !clientID.allSatisfy(\.isNumber) {
                return clientID
            }
            return "Game"
        }()
        let typeRaw = (dict["type"] as? Int) ?? 0
        let type = ActivityType(rawValue: typeRaw) ?? .playing
        let details = dict["details"] as? String
        let state = dict["state"] as? String
        let url = dict["url"] as? String
        let instance = dict["instance"] as? Bool
        let flags = dict["flags"] as? Int

        var timestamps: ActivityTimestamps?
        if let tsDict = dict["timestamps"] as? [String: Any] {
            var start = (tsDict["start"] as? NSNumber)?.int64Value
            var end = (tsDict["end"] as? NSNumber)?.int64Value
            // Local Discord IPC sends timestamps in seconds (< 100_000_000_000).
            // Convert to milliseconds to align with Gateway and Discord rich presence expectations.
            if let startSeconds = start, startSeconds > 0, startSeconds < 100_000_000_000 {
                start = startSeconds * 1000
            }
            if let endSeconds = end, endSeconds > 0, endSeconds < 100_000_000_000 {
                end = endSeconds * 1000
            }
            if start != nil || end != nil {
                timestamps = ActivityTimestamps(start: start, end: end)
            }
        }

        var assets: ActivityAssets?
        if let assetsDict = dict["assets"] as? [String: Any] {
            assets = ActivityAssets(
                largeImage: assetsDict["large_image"] as? String,
                largeText: assetsDict["large_text"] as? String,
                smallImage: assetsDict["small_image"] as? String,
                smallText: assetsDict["small_text"] as? String
            )
        }

        var party: ActivityParty?
        if let partyDict = dict["party"] as? [String: Any] {
            let id = partyDict["id"] as? String
            let size = partyDict["size"] as? [Int]
            party = ActivityParty(
                id: id,
                currentSize: size?.indices.contains(0) == true ? size?[0] : nil,
                maxSize: size?.indices.contains(1) == true ? size?[1] : nil
            )
        }

        var secrets: ActivitySecrets?
        if let secretsDict = dict["secrets"] as? [String: Any] {
            secrets = ActivitySecrets(
                join: secretsDict["join"] as? String,
                spectate: secretsDict["spectate"] as? String,
                match: secretsDict["match"] as? String
            )
        }

        var buttons: [ActivityButton]?
        if let buttonsList = dict["buttons"] as? [[String: Any]] {
            buttons = buttonsList.compactMap { btn in
                guard let label = btn["label"] as? String,
                      let url = btn["url"] as? String else { return nil }
                return ActivityButton(label: label, url: url)
            }
        }

        return OutgoingActivityPayload(
            name: name,
            type: type,
            url: url,
            details: details,
            state: state,
            timestamps: timestamps,
            assets: assets,
            party: party,
            secrets: secrets,
            instance: instance,
            flags: flags,
            buttons: buttons,
            applicationId: clientID
        )
    }

    private func sendResponse(cmd: String, data: Any, nonce: String?) {
        var dict: [String: Any] = [
            "cmd": cmd,
            "data": data,
            "evt": NSNull(),
        ]
        if let nonce {
            dict["nonce"] = nonce
        } else {
            dict["nonce"] = NSNull()
        }
        sendFrame(opcode: 1, jsonObject: dict)
    }

    private func sendReadyEvent(clientID: String) {
        let readyData: [String: Any] = [
            "cmd": "DISPATCH",
            "data": [
                "v": 1,
                "config": [
                    "cdn_host": "cdn.discordapp.com",
                    "api_endpoint": "//discord.com/api",
                    "environment": "production",
                ],
                "user": [
                    "id": "1",
                    "username": "SakuraCord",
                    "discriminator": "0000",
                    "avatar": NSNull(),
                ],
            ],
            "evt": "READY",
            "nonce": NSNull(),
        ]
        sendFrame(opcode: 1, jsonObject: readyData)
    }

    private func sendFrame(opcode: UInt32, jsonObject: Any) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: jsonObject) else { return }
        var frame = Data()
        frame.appendUInt32LittleEndian(opcode)
        frame.appendUInt32LittleEndian(UInt32(jsonData.count))
        frame.append(jsonData)

        var bytesSent = 0
        let total = frame.count
        var retries = 0
        while bytesSent < total {
            let written = frame.withUnsafeBytes { ptr in
                write(clientFD, ptr.baseAddress! + bytesSent, total - bytesSent)
            }
            if written > 0 {
                bytesSent += written
                retries = 0
            } else if written < 0 {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK {
                    retries += 1
                    if retries > 20 {
                        logger.warning("IPC client socket write timed out (EAGAIN); closing connection.")
                        stop()
                        return
                    }
                    usleep(1000)
                    continue
                }
                logger.debug("Write failed on IPC client socket: errno \(err)")
                stop()
                return
            } else {
                stop()
                return
            }
        }
    }
}

public nonisolated final class DiscordIPCServer: @unchecked Sendable {
    public static let maxFramePayloadSize = 1024 * 1024 // 1 MB
    public static let maxClientCount = 10

    public let coordinator: ActivityCoordinator
    private let requestedSocketPath: String?
    private var boundSocketPath: String?
    private var boundSymlinkPath: String?
    private var listenFD: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "dev.sakuracord.ipc-server", qos: .userInitiated)
    private var activeClients: [UUID: DiscordIPCClientSession] = [:]
    private let logger = Logger(subsystem: "dev.sakuracord", category: "DiscordIPCServer")
    private var isRunning = false

    public init(
        coordinator: ActivityCoordinator,
        socketPath: String? = nil
    ) {
        self.coordinator = coordinator
        self.requestedSocketPath = socketPath
    }

    deinit {
        stop()
    }

    public var currentBoundSocketPath: String? {
        queue.sync { boundSocketPath }
    }

    public var isServerRunning: Bool {
        queue.sync { isRunning }
    }

    public static func candidateSocketPaths() -> [String] {
        var paths: [String] = []
        let tempDirs = [
            ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"],
            ProcessInfo.processInfo.environment["TMPDIR"],
            ProcessInfo.processInfo.environment["TMP"],
            ProcessInfo.processInfo.environment["TEMP"],
            "/tmp",
        ].compactMap { $0 }.filter { !$0.isEmpty }

        for baseDir in tempDirs {
            let dir = baseDir.hasSuffix("/") ? String(baseDir.dropLast()) : baseDir
            for index in 0 ... 9 {
                let candidate = "\(dir)/discord-ipc-\(index)"
                if !paths.contains(candidate) {
                    paths.append(candidate)
                }
            }
        }
        return paths.isEmpty ? (0 ... 9).map { "/tmp/discord-ipc-\($0)" } : paths
    }

    public enum SocketListenerStatus: Sendable, Equatable {
        case active
        case stale
        case unverified
    }

    /// Probes whether a process is actively listening on a Unix domain socket path (or a symlink pointing to one).
    public static func probeSocketListener(at path: String) -> SocketListenerStatus {
        let testFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard testFD >= 0 else { return .unverified }
        defer { close(testFD) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            return .unverified
        }

        withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            _ = pathBytes.withUnsafeBufferPointer { buf in
                memcpy(ptr, buf.baseAddress!, buf.count)
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddrPtr in
                Darwin.connect(testFD, sockAddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if connectResult == 0 {
            return .active
        }

        let err = errno
        if err == ECONNREFUSED || err == ENOENT {
            return .stale
        }

        return .unverified
    }

    /// Purges stale or broken IPC sockets in a directory if no active process is listening.
    public static func purgeStaleSockets(in directory: String = "/tmp") {
        for index in 0 ... 9 {
            let socketPath = "\(directory)/discord-ipc-\(index)"
            var statBuf = stat()
            // Check if file or symlink exists (lstat catches broken symlinks too)
            guard lstat(socketPath, &statBuf) == 0 else { continue }

            let fileType = statBuf.st_mode & S_IFMT
            if fileType == S_IFLNK {
                var targetStat = stat()
                if stat(socketPath, &targetStat) != 0 {
                    // Broken symlink (target does not exist) -> safe to purge
                    unlink(socketPath)
                } else if (targetStat.st_mode & S_IFMT) == S_IFSOCK {
                    // Symlink points to a socket; safe to purge only if confirmed dead
                    if probeSocketListener(at: socketPath) == .stale {
                        unlink(socketPath)
                    }
                }
            } else if fileType == S_IFSOCK {
                // Unix domain socket file; safe to purge only if confirmed dead
                if probeSocketListener(at: socketPath) == .stale {
                    unlink(socketPath)
                }
            }
        }
    }

    /// Determines whether a destination path can be safely replaced by SakuraCord's symlink.
    /// Occupied sockets or symlinks belonging to active listeners are never touched.
    static func canReplaceWithSymlink(at symlinkPath: String) -> Bool {
        var statBuf = stat()
        if lstat(symlinkPath, &statBuf) != 0 {
            // Path does not exist; free to create symlink
            return true
        }

        let fileType = statBuf.st_mode & S_IFMT
        if fileType == S_IFLNK {
            var targetStat = stat()
            if stat(symlinkPath, &targetStat) != 0 {
                // Target does not exist (broken symlink); safe to remove and replace
                unlink(symlinkPath)
                return true
            }
            if (targetStat.st_mode & S_IFMT) == S_IFSOCK {
                // Symlink points to a socket; replace only if confirmed dead
                if probeSocketListener(at: symlinkPath) == .stale {
                    unlink(symlinkPath)
                    return true
                }
            }
            // Active listener, unverified probe, or non-socket target; leave occupied path alone
            return false
        }

        if fileType == S_IFSOCK {
            // Socket file; replace only if confirmed dead
            if probeSocketListener(at: symlinkPath) == .stale {
                unlink(symlinkPath)
                return true
            }
            // Active socket belonging to another client or unverified probe; leave occupied path alone
            return false
        }

        // Regular file, directory, or other file type; leave occupied path alone
        return false
    }

    /// Removes a symlink only if it still points to this server's bound socket path.
    static func removeSymlinkIfOwned(symlinkPath: String, targetPath: String) {
        var statBuf = stat()
        guard lstat(symlinkPath, &statBuf) == 0,
              (statBuf.st_mode & S_IFMT) == S_IFLNK else {
            return
        }

        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let bytesRead = readlink(symlinkPath, &buffer, buffer.count - 1)
        guard bytesRead > 0 else { return }
        buffer[bytesRead] = 0
        let destination = String(cString: buffer)
        if destination == targetPath {
            unlink(symlinkPath)
        }
    }

    public func start() throws {
        try queue.sync {
            guard !isRunning else { return }
            Self.purgeStaleSockets(in: "/tmp")
            if let tmpdir = ProcessInfo.processInfo.environment["TMPDIR"], !tmpdir.isEmpty {
                let dir = tmpdir.hasSuffix("/") ? String(tmpdir.dropLast()) : tmpdir
                if dir != "/tmp" {
                    Self.purgeStaleSockets(in: dir)
                }
            }

            let pathsToTry = requestedSocketPath.map { [$0] } ?? Self.candidateSocketPaths()
            var boundPath: String?
            var boundFD: Int32 = -1

            for path in pathsToTry {
                if let fd = tryBindSocket(at: path) {
                    boundFD = fd
                    boundPath = path
                    break
                }
            }

            guard let path = boundPath, boundFD >= 0 else {
                throw NSError(domain: "dev.sakuracord.ipc", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Could not bind any Discord IPC socket path.",
                ])
            }

            self.boundSocketPath = path
            self.listenFD = boundFD
            self.isRunning = true

            // On macOS, if bound inside a user-specific temp directory (TMPDIR), maintain
            // a symlink in /tmp so cross-platform games/mods hardcoding /tmp can connect.
            if requestedSocketPath == nil, !path.hasPrefix("/tmp/"), let fileName = path.split(separator: "/").last {
                let symlinkPath = "/tmp/\(fileName)"
                if Self.canReplaceWithSymlink(at: symlinkPath), symlink(path, symlinkPath) == 0 {
                    self.boundSymlinkPath = symlinkPath
                }
            }

            let source = DispatchSource.makeReadSource(fileDescriptor: boundFD, queue: queue)
            source.setEventHandler { [weak self] in
                self?.acceptConnection()
            }
            let socketToClean = path
            let symlinkToClean = self.boundSymlinkPath
            source.setCancelHandler {
                close(boundFD)
                if let symlinkToClean {
                    Self.removeSymlinkIfOwned(symlinkPath: symlinkToClean, targetPath: socketToClean)
                }
                unlink(socketToClean)
            }
            self.listenSource = source
            source.resume()
            logger.info("Discord IPC Server listening at \(path)")
        }
    }

    public func stop() {
        queue.sync {
            guard isRunning else { return }
            isRunning = false
            for client in activeClients.values {
                client.stop()
            }
            activeClients.removeAll()
            if let listenSource {
                listenSource.cancel()
                self.listenSource = nil
            } else if listenFD >= 0 {
                close(listenFD)
            }
            listenFD = -1
            if let boundSymlinkPath {
                if let boundSocketPath {
                    Self.removeSymlinkIfOwned(symlinkPath: boundSymlinkPath, targetPath: boundSocketPath)
                }
                self.boundSymlinkPath = nil
            }
            if let boundSocketPath {
                unlink(boundSocketPath)
                self.boundSocketPath = nil
            }
        }
    }

    private func tryBindSocket(at path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            return nil
        }

        withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            _ = pathBytes.withUnsafeBufferPointer { buf in
                memcpy(ptr, buf.baseAddress!, buf.count)
            }
        }

        var statBuf = stat()
        if lstat(path, &statBuf) == 0 {
            // Reclaim occupied path only after confirming no active listener remains
            guard Self.probeSocketListener(at: path) == .stale else {
                close(fd)
                return nil
            }
            unlink(path)
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddrPtr in
                Darwin.bind(fd, sockAddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            close(fd)
            return nil
        }

        guard Darwin.listen(fd, 10) == 0 else {
            close(fd)
            unlink(path)
            return nil
        }

        chmod(path, 0o700)
        return fd
    }
    private func acceptConnection() {
        guard isRunning, listenFD >= 0 else { return }
        var clientAddr = sockaddr_un()
        var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockAddrPtr in
                Darwin.accept(listenFD, sockAddrPtr, &clientAddrLen)
            }
        }
        guard clientFD >= 0 else { return }

        var noSigpipe: Int32 = 1
        _ = setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

        if activeClients.count >= Self.maxClientCount {
            logger.warning("Max IPC client count reached (\(Self.maxClientCount)); rejecting connection.")
            close(clientFD)
            return
        }

        _ = fcntl(clientFD, F_SETFD, FD_CLOEXEC)
        let flags = fcntl(clientFD, F_GETFL, 0)
        _ = fcntl(clientFD, F_SETFL, flags | O_NONBLOCK)

        let session = DiscordIPCClientSession(
            clientFD: clientFD,
            coordinator: coordinator,
            queue: queue,
            onClose: { [weak self] sessionID in
                self?.removeClient(id: sessionID)
            }
        )
        activeClients[session.id] = session
        session.start()
    }

    private func removeClient(id: UUID) {
        queue.async { [weak self] in
            self?.activeClients.removeValue(forKey: id)
        }
    }
}
