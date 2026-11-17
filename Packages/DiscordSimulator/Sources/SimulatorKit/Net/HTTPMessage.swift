import Foundation

public struct HTTPRequest: Sendable {
    public var method: String
    /// The request target exactly as sent, including the query.
    public var target: String
    /// The percent-encoded path without the query, exactly as sent.
    public var path: String
    public var query: [String: [String]]
    public var headers: [(name: String, value: String)]
    public var body: Data
    /// The 1-based accept order of the TCP connection this request arrived on.
    public var connectionID: Int

    public init(
        method: String,
        target: String,
        headers: [(name: String, value: String)] = [],
        body: Data = Data(),
        connectionID: Int = 0
    ) {
        self.method = method
        self.target = target
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        path = String(parts[0])
        query = parts.count > 1 ? Self.decodeQuery(parts[1]) : [:]
        self.headers = headers
        self.body = body
        self.connectionID = connectionID
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private static func decodeQuery(_ query: Substring) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            result[decode(parts[0]), default: []].append(parts.count > 1 ? decode(parts[1]) : "")
        }
        return result
    }

    private static func decode(_ component: Substring) -> String {
        let spaced = component.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json(_ status: Int, _ body: JSON, headers: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "application/json")] + headers, body: body.data())
    }

    /// Discord's JSON error body: `{"message": …, "code": …}`.
    public static func discordError(_ status: Int, _ message: String, code: Int = 0) -> HTTPResponse {
        .json(status, .object(JSONObject([("message", .string(message)), ("code", .int(Int64(code)))])))
    }

    public static func empty(_ status: Int) -> HTTPResponse { HTTPResponse(status: status) }

    public static func bytes(_ status: Int, _ data: Data, contentType: String) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", contentType)], body: data)
    }

    /// The server owns framing, so handler-supplied framing headers are replaced.
    func serialized(keepAlive: Bool) -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reasonPhrase(status))\r\n"
        for (name, value) in headers where !["content-length", "connection"].contains(name.lowercased()) {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(body.count)\r\nConnection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    private static let reasonPhrases: [Int: String] = [
        100: "Continue",
        101: "Switching Protocols",
        200: "OK",
        201: "Created",
        202: "Accepted",
        204: "No Content",
        206: "Partial Content",
        301: "Moved Permanently",
        302: "Found",
        304: "Not Modified",
        307: "Temporary Redirect",
        308: "Permanent Redirect",
        400: "Bad Request",
        401: "Unauthorized",
        403: "Forbidden",
        404: "Not Found",
        405: "Method Not Allowed",
        409: "Conflict",
        410: "Gone",
        413: "Content Too Large",
        415: "Unsupported Media Type",
        422: "Unprocessable Content",
        429: "Too Many Requests",
        431: "Request Header Fields Too Large",
        500: "Internal Server Error",
        501: "Not Implemented",
        502: "Bad Gateway",
        503: "Service Unavailable",
        504: "Gateway Timeout",
    ]

    static func reasonPhrase(_ status: Int) -> String {
        reasonPhrases[status] ?? "Unknown"
    }
}
