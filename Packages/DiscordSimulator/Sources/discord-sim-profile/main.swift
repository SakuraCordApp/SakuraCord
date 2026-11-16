import Foundation
import SimulatorKit

/// `discord-sim-profile extract <capture.jsonl>... --out FILE [--seed N] [--mark MARK]` writes
/// an account's structure-only profile. The first READY (under the given dcap
/// mark, if any) picks the account; every capture of it adds to the activity rates.
let arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard arguments.first == "extract" else { fail("usage: discord-sim-profile extract <capture.jsonl>... --out FILE [--seed N] [--mark MARK]") }
var files: [URL] = []
var output: URL?
var seed: UInt64 = 1
var mark: String?
var iterator = arguments.dropFirst().makeIterator()
while let argument = iterator.next() {
    switch argument {
    case "--out": output = iterator.next().map { URL(filePath: $0) }
    case "--seed": seed = iterator.next().flatMap { UInt64($0) } ?? seed
    case "--mark": mark = iterator.next()
    default: files.append(URL(filePath: argument))
    }
}
guard let output, !files.isEmpty else { fail("usage: discord-sim-profile extract <capture.jsonl>... --out FILE [--seed N] [--mark MARK]") }
var extractor = ProfileExtractor(seed: seed, mark: mark)
for file in files {
    do { try extractor.absorb(captureFile: file) } catch { fail("\(file.path): \(error)") }
}
do {
    let profile = try extractor.profile()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(profile).write(to: output)
    print("servers: \(profile.servers.count), folders: \(profile.folders.count), measured hours: \((extractor.hours * 10).rounded() / 10)")
} catch {
    fail("\(error)")
}
