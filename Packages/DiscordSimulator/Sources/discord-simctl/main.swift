import Foundation

/// Command-line client for the simulator's control API.
///
///   discord-simctl [--port 47100] world | log [LEVEL] | routes | health
///   discord-simctl post <channel> <author> <content> [--embed TITLE DESCRIPTION] [--reply ID] [--photo WxH]
///   discord-simctl edit <channel> <message-id> <content> | delete <channel> <message-id>
///   discord-simctl react <channel> <message-id> <author> <emoji>
///   discord-simctl typing <channel> <author>
///   discord-simctl ring <caller>          (an incoming DM call to the signed-in user)
///   discord-simctl nitro <user> none|basic|nitro|classic
///   discord-simctl boosts <guild> <count>
///   discord-simctl presence <user> online|idle|dnd|offline [activity text]
///   discord-simctl network instant|lan|broadband|mobile | network <latency-ms> <jitter-ms> [down-Bps] [up-Bps]
///   discord-simctl fault 429|500|502|503 [route-substring] [count] | fault gateway-drop|gateway-reconnect|gateway-invalid-session|gateway-close-resumable
///   discord-simctl faults-clear
///   discord-simctl clock freeze|unfreeze|advance <seconds>
///   discord-simctl script <name> [key=value]...
var arguments = Array(CommandLine.arguments.dropFirst())
var basePort = 47100
if let index = arguments.firstIndex(of: "--port"), index + 1 < arguments.count, let port = Int(arguments[index + 1]) {
    basePort = port
    arguments.removeSubrange(index ... index + 1)
}

func usage() -> Never {
    FileHandle.standardError.write(Data("usage: see the header of Sources/discord-simctl/main.swift\n".utf8))
    exit(2)
}

@MainActor
func call(_ method: String, _ path: String, _ body: [String: Any]? = nil) async -> Never {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(basePort + 9)/control/\(path)")!)
    request.httpMethod = method
    if let body {
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    do {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            print(String(bytes: pretty, encoding: .utf8) ?? "")
        } else {
            print(String(bytes: data, encoding: .utf8) ?? "")
        }
        exit(status < 400 ? 0 : 1)
    } catch {
        FileHandle.standardError.write(Data("discord-simctl: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

@MainActor
func argument(_ index: Int) -> String {
    guard index < arguments.count else { usage() }
    return arguments[index]
}

switch arguments.first ?? "" {
case "health", "world", "routes": await call("GET", arguments[0])
case "log": await call("GET", "log?level=\(arguments.count > 1 ? arguments[1] : "WARN")")
case "post":
    var body: [String: Any] = ["channel": argument(1), "author": argument(2), "content": argument(3)]
    var index = 4
    while index < arguments.count {
        switch arguments[index] {
        case "--embed":
            body["embeds"] = [["type": "rich", "title": argument(index + 1), "description": argument(index + 2), "color": 0x5865F2]]
            index += 3
        case "--reply":
            body["reply_to"] = argument(index + 1)
            index += 2
        case "--photo":
            let size = argument(index + 1).split(separator: "x").compactMap { Int($0) }
            body["attachments"] = [["width": size.first ?? 1280, "height": size.last ?? 960]]
            index += 2
        default: usage()
        }
    }
    await call("POST", "messages", body)
case "edit": await call("PATCH", "messages/\(argument(2))", ["channel": argument(1), "content": argument(3)])
case "delete": await call("DELETE", "messages/\(argument(2))", ["channel": argument(1)])
case "react": await call("POST", "reactions", ["channel": argument(1), "message_id": argument(2), "author": argument(3), "emoji": argument(4)])
case "typing": await call("POST", "typing", ["channel": argument(1), "author": argument(2)])
case "ring": await call("POST", "calls", ["caller": argument(1)])
case "nitro":
    let types = ["none": 0, "classic": 1, "nitro": 2, "basic": 3]
    guard let type = types[argument(2)] else { usage() }
    await call("PATCH", "users/\(argument(1))", ["premium_type": type])
case "boosts": await call("PUT", "guilds/\(argument(1))/boosts", ["count": Int(argument(2)) ?? usage()])
case "presence":
    var body: [String: Any] = ["user": argument(1), "status": argument(2)]
    if arguments.count > 3 { body["activities"] = [["type": 4, "name": "Custom Status", "state": arguments[3...].joined(separator: " ")]] }
    await call("POST", "presence", body)
case "network":
    if let latency = Double(argument(1)) {
        var body: [String: Any] = ["latency_ms": latency, "jitter_ms": Double(argument(2)) ?? 0]
        if arguments.count > 3 { body["download_bytes_per_second"] = Double(arguments[3]) }
        if arguments.count > 4 { body["upload_bytes_per_second"] = Double(arguments[4]) }
        await call("PUT", "network", body)
    }
    await call("PUT", "network", ["profile": argument(1)])
case "fault":
    var body: [String: Any] = ["kind": argument(1)]
    if arguments.count > 2 { body["route"] = arguments[2] }
    if arguments.count > 3 { body["count"] = Int(arguments[3]) }
    await call("POST", "faults", body)
case "faults-clear": await call("DELETE", "faults")
case "clock":
    switch argument(1) {
    case "freeze": await call("POST", "clock", ["freeze": true])
    case "unfreeze": await call("POST", "clock", ["freeze": false])
    case "advance": await call("POST", "clock", ["advance_seconds": Double(argument(2)) ?? usage()])
    default: usage()
    }
case "script":
    var params: [String: Any] = [:]
    for pair in arguments.dropFirst(2) {
        let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { usage() }
        params[parts[0]] = Double(parts[1]).map { $0 == $0.rounded() ? Int($0) as Any : $0 as Any } ?? parts[1]
    }
    await call("POST", "scripts", ["name": argument(1), "params": params])
default: usage()
}
