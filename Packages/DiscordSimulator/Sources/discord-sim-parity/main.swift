import Foundation
import SimulatorKit

/// `discord-sim-parity extract <capture.jsonl>... --out DIR` builds the committed
/// shape catalog from dcap captures. `discord-sim-parity check [--break SUBJECT]`
/// runs the simulator's parity suite against the bundled catalog.
let arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

switch arguments.first {
case "extract":
    var files: [URL] = []
    var output: URL?
    var iterator = arguments.dropFirst().makeIterator()
    while let argument = iterator.next() {
        if argument == "--out" { output = iterator.next().map { URL(filePath: $0) } } else { files.append(URL(filePath: argument)) }
    }
    guard let output, !files.isEmpty else { fail("usage: discord-sim-parity extract <capture.jsonl>... --out DIR") }
    var extractor = ShapeExtractor()
    for file in files {
        do { try extractor.absorb(captureFile: file) } catch { fail("\(file.path): \(error)") }
    }
    do { try extractor.catalog.write(to: output) } catch { fail("write failed: \(error)") }
    print("routes: \(extractor.catalog.routes.count), events: \(extractor.catalog.gateway.count), sequences: \(extractor.catalog.sequences.keys.sorted())")
case "check":
    // `--break SUBJECT` drops the first field of that subject's responses, to prove the suite fails.
    var mutation: ParitySuite.Mutation?
    if let index = arguments.firstIndex(of: "--break"), index + 1 < arguments.count {
        let target = arguments[index + 1]
        mutation = { subject, body in subject == target ? ParitySuite.dropFirstField(body) : body }
    }
    let report = await ParitySuite.run(mutate: mutation)
    print(report.summary)
    var passed = report.passed
    // The generated account modes, unless proving the suite fails.
    if mutation == nil {
        for scenario in ["demo", "demo-large"] {
            let world = await ParitySuite.runWorld(scenario: scenario)
            print("\(scenario): \(world.summary)")
            passed = passed && world.passed
        }
        let voice = await ParitySuite.runVoice(scenario: "demo")
        print("demo voice: \(voice.summary)")
        passed = passed && voice.passed
    }
    exit(passed ? 0 : 1)
default:
    fail("usage: discord-sim-parity extract <capture.jsonl>... --out DIR | check")
}
