import Foundation

/// `multipart/form-data` message bodies: `payload_json` plus `files[n]` parts.
enum MultipartForm {
    struct File: Sendable {
        var fieldName: String
        var filename: String?
        var data: Data
    }

    static func messageBody(_ request: HTTPRequest) throws -> (JSON, [File]) {
        let contentType = request.header("Content-Type") ?? ""
        guard contentType.lowercased().hasPrefix("multipart/form-data"),
              let boundary = contentType.components(separatedBy: "boundary=").last?.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        else {
            return (request.body.isEmpty ? .object(JSONObject()) : try parseJSON(request.body), [])
        }
        var payload: JSON = .object(JSONObject())
        var files: [File] = []
        for part in parts(request.body, boundary: boundary) {
            let name = part.headers["content-disposition"].flatMap { attribute("name", in: $0) } ?? ""
            if name == "payload_json" {
                payload = try parseJSON(part.body)
            } else {
                files.append(File(fieldName: name, filename: part.headers["content-disposition"].flatMap { attribute("filename", in: $0) }, data: part.body))
            }
        }
        return (payload, files)
    }

    private static func parseJSON(_ data: Data) throws -> JSON {
        do { return try JSON.parse(data) } catch { throw WorldError.invalidBody("body is not JSON") }
    }

    private static func attribute(_ name: String, in header: String) -> String? {
        for piece in header.split(separator: ";") {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\(name)=") {
                return String(trimmed.dropFirst(name.count + 1)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }

    private static func parts(_ body: Data, boundary: String) -> [(headers: [String: String], body: Data)] {
        let delimiter = Data("--\(boundary)".utf8)
        var results: [(headers: [String: String], body: Data)] = []
        var cursor = body.startIndex
        guard let first = body.range(of: delimiter, in: cursor ..< body.endIndex) else { return [] }
        cursor = first.upperBound
        while let next = body.range(of: delimiter, in: cursor ..< body.endIndex) {
            var chunk = body[cursor ..< next.lowerBound]
            if chunk.starts(with: Data("\r\n".utf8)) { chunk = chunk.dropFirst(2) }
            if chunk.suffix(2) == Data("\r\n".utf8) { chunk = chunk.dropLast(2) }
            if let split = chunk.range(of: Data("\r\n\r\n".utf8)) {
                var headers: [String: String] = [:]
                for line in (String(bytes: chunk[chunk.startIndex ..< split.lowerBound], encoding: .utf8) ?? "").components(separatedBy: "\r\n") {
                    let pair = line.split(separator: ":", maxSplits: 1)
                    if pair.count == 2 { headers[pair[0].lowercased()] = pair[1].trimmingCharacters(in: .whitespaces) }
                }
                results.append((headers, Data(chunk[split.upperBound...])))
            }
            cursor = next.upperBound
        }
        return results
    }
}
