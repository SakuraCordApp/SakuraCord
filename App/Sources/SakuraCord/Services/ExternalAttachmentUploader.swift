import Foundation

nonisolated enum ExternalAttachmentHostingService: String, CaseIterable, Sendable {
    case catbox
    case litterbox

    static let megabyte: Int64 = 1_000_000

    var displayName: String {
        switch self {
        case .catbox: "Catbox"
        case .litterbox: "Litterbox"
        }
    }

    var maximumFileSize: Int64 {
        switch self {
        case .catbox: 200 * Self.megabyte
        case .litterbox: 1_000 * Self.megabyte
        }
    }

    var endpoint: URL {
        switch self {
        case .catbox:
            URL(string: "https://catbox.moe/user/api.php")!
        case .litterbox:
            URL(string: "https://litterbox.catbox.moe/resources/internals/api.php")!
        }
    }

    var responseHost: String {
        switch self {
        case .catbox: "files.catbox.moe"
        case .litterbox: "litter.catbox.moe"
        }
    }

    func canUpload(fileURL: URL, size: Int64) -> Bool {
        guard size <= maximumFileSize else { return false }
        let fileExtension = fileURL.pathExtension.lowercased()
        return !Self.blockedExtensions.contains(fileExtension)
    }

    private static let blockedExtensions: Set<String> = ["exe", "scr", "cpl", "doc", "docx", "jar"]
}

nonisolated protocol ExternalAttachmentUploading: Sendable {
    func upload(fileURL: URL, using service: ExternalAttachmentHostingService) async throws -> URL
}

nonisolated struct CatboxAttachmentUploader: ExternalAttachmentUploading {
    let session: URLSession

    init() {
        session = URLSession(configuration: Self.sessionConfiguration())
    }

    init(session: URLSession) {
        self.session = session
    }

    static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return configuration
    }

    func upload(fileURL: URL, using service: ExternalAttachmentHostingService) async throws -> URL {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize,
              service.canUpload(fileURL: fileURL, size: Int64(fileSize))
        else {
            throw ExternalAttachmentUploadError.ineligibleFile
        }
        let boundary = "SakuraCord-\(UUID().uuidString)"
        let multipartURL = try Self.makeMultipartFile(
            sourceURL: fileURL,
            service: service,
            boundary: boundary
        )
        defer { try? FileManager.default.removeItem(at: multipartURL.deletingLastPathComponent()) }

        var request = URLRequest(url: service.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 10 * 60
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )

        let (data, response) = try await session.upload(for: request, fromFile: multipartURL)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else {
            throw ExternalAttachmentUploadError.invalidResponse
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw ExternalAttachmentUploadError.httpStatus(response.statusCode)
        }
        guard data.count <= 4_096,
              let value = String(data: data, encoding: .utf8)?.trimmingCharacters(
                in: .whitespacesAndNewlines
              ),
              let result = URL(string: value),
              result.scheme == "https",
              result.host?.lowercased() == service.responseHost
        else {
            throw ExternalAttachmentUploadError.invalidResponse
        }
        return result
    }

    static func makeMultipartFile(
        sourceURL: URL,
        service: ExternalAttachmentHostingService,
        boundary: String
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SakuraCord-External-Upload-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        do {
            let bodyURL = directory.appendingPathComponent("multipart-body")
            guard FileManager.default.createFile(atPath: bodyURL.path, contents: nil) else {
                throw ExternalAttachmentUploadError.couldNotPrepareUpload
            }
            let destination = try FileHandle(forWritingTo: bodyURL)
            defer { try? destination.close() }

            try writeField(
                name: "reqtype",
                value: "fileupload",
                boundary: boundary,
                to: destination
            )
            if service == .litterbox {
                try writeField(
                    name: "time",
                    value: "24h",
                    boundary: boundary,
                    to: destination
                )
            }

            let filename = sanitizedFilename(fileURL: sourceURL)
            try destination.write(contentsOf: Data(
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"fileToUpload\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8
            ))
            let source = try FileHandle(forReadingFrom: sourceURL)
            defer { try? source.close() }
            while let chunk = try source.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
                try Task.checkCancellation()
                try destination.write(contentsOf: chunk)
            }
            try destination.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            return bodyURL
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func writeField(
        name: String,
        value: String,
        boundary: String,
        to destination: FileHandle
    ) throws {
        try destination.write(contentsOf: Data(
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8
        ))
    }

    private static func sanitizedFilename(fileURL: URL) -> String {
        let value = fileURL.lastPathComponent
            .replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
        return value.isEmpty ? "upload.bin" : value
    }
}

nonisolated enum ExternalAttachmentUploadError: LocalizedError {
    case couldNotPrepareUpload
    case ineligibleFile
    case httpStatus(Int)
    case invalidResponse
    case conversationChanged(URL)

    var errorDescription: String? {
        switch self {
        case .couldNotPrepareUpload:
            "The temporary upload body could not be prepared."
        case .ineligibleFile:
            "The file does not meet this host's size or file-type rules."
        case .httpStatus(let status):
            "The file host rejected the upload (HTTP \(status))."
        case .invalidResponse:
            "The file host returned an invalid link."
        case .conversationChanged(let link):
            "The conversation changed before the link could be inserted. Your uploaded link is \(link.absoluteString)"
        }
    }
}
