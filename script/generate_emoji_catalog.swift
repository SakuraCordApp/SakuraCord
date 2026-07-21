#!/usr/bin/env swift

import Foundation

private enum GeneratorError: LocalizedError {
    case usage
    case invalidUnicodeData

    var errorDescription: String? {
        switch self {
        case .usage:
            "Usage: generate_emoji_catalog.swift <emoji-test.txt> <joypixels.raw.json> <output.json>"
        case .invalidUnicodeData:
            "The Unicode emoji input did not contain fully-qualified emoji entries."
        }
    }
}

private enum ShortcodeAliases: Decodable {
    case one(String)
    case many([String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let aliases = try? container.decode([String].self) {
            self = .many(aliases)
        } else {
            self = .one(try container.decode(String.self))
        }
    }

    var values: [String] {
        switch self {
        case let .one(value): [value]
        case let .many(values): values
        }
    }
}

private struct ParsedEmoji {
    let scalars: [UnicodeScalar]
    let value: String
    let name: String
    let aliases: String
    let category: String

    var baseKey: String {
        String(String.UnicodeScalarView(scalars.filter {
            skinToneName(for: $0.value) == nil && $0.value != 0xFE0F
        }))
    }

    var skinTone: String? {
        let tones = scalars.compactMap { skinToneName(for: $0.value) }
        guard let first = tones.first, tones.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    var hasSkinToneModifier: Bool {
        scalars.contains { skinToneName(for: $0.value) != nil }
    }

    var shortcodeKeys: [String] {
        let all = scalars.map { String($0.value, radix: 16, uppercase: true) }
        let withoutVariationSelectors = scalars
            .filter { $0.value != 0xFE0F }
            .map { String($0.value, radix: 16, uppercase: true) }
        return [all.joined(separator: "-"), withoutVariationSelectors.joined(separator: "-")]
    }
}

private struct Catalog: Encodable {
    let formatVersion = 1
    let unicodeVersion: String
    let sourceEntryCount: Int
    let items: [CatalogItem]
}

private struct CatalogItem: Encodable {
    let value: String
    let name: String
    let aliases: String
    let category: String
    let skinToneVariants: [String: String]
    let shortcodes: [String]
}

private func skinToneName(for codePoint: UInt32) -> String? {
    switch codePoint {
    case 0x1F3FB: "light"
    case 0x1F3FC: "mediumLight"
    case 0x1F3FD: "medium"
    case 0x1F3FE: "mediumDark"
    case 0x1F3FF: "dark"
    default: nil
    }
}

private func categoryName(for unicodeGroup: String) -> String? {
    switch unicodeGroup {
    case "Smileys & Emotion": "smileys"
    case "People & Body": "people"
    case "Animals & Nature": "nature"
    case "Food & Drink": "food"
    case "Activities": "activities"
    case "Travel & Places": "travel"
    case "Objects": "objects"
    case "Symbols": "symbols"
    case "Flags": "flags"
    default: nil
    }
}

private func generate() throws {
    guard CommandLine.arguments.count == 4 else { throw GeneratorError.usage }
    let unicodeURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let shortcodesURL = URL(fileURLWithPath: CommandLine.arguments[2])
    let outputURL = URL(fileURLWithPath: CommandLine.arguments[3])

    let unicodeSource = try String(contentsOf: unicodeURL, encoding: .utf8)
    let shortcodeData = try Data(contentsOf: shortcodesURL)
    let decodedShortcodes = try JSONDecoder().decode([String: ShortcodeAliases].self, from: shortcodeData)
    let shortcodes = decodedShortcodes.mapValues(\.values)

    let unicodeVersion = unicodeSource.split(separator: "\n")
        .first { $0.hasPrefix("# Version: ") }
        .map { String($0.dropFirst("# Version: ".count)) } ?? "unknown"
    var category: String?
    var subgroup = ""
    var parsed: [ParsedEmoji] = []
    parsed.reserveCapacity(4_000)

    for rawLine in unicodeSource.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("# group: ") {
            category = categoryName(for: String(line.dropFirst("# group: ".count)))
            continue
        }
        if line.hasPrefix("# subgroup: ") {
            subgroup = String(line.dropFirst("# subgroup: ".count))
                .replacingOccurrences(of: "-", with: " ")
            continue
        }
        guard let category,
              line.contains("; fully-qualified"),
              let hash = line.firstIndex(of: "#"),
              let semicolon = line.firstIndex(of: ";") else { continue }

        let scalars = line[..<semicolon]
            .split(whereSeparator: \.isWhitespace)
            .compactMap { UInt32($0, radix: 16).flatMap(UnicodeScalar.init) }
        guard !scalars.isEmpty else { continue }
        let metadata = line[line.index(after: hash)...]
            .trimmingCharacters(in: .whitespaces)
            .split(maxSplits: 2, whereSeparator: \.isWhitespace)
        guard metadata.count == 3 else { continue }
        parsed.append(ParsedEmoji(
            scalars: scalars,
            value: String(String.UnicodeScalarView(scalars)),
            name: String(metadata[2]),
            aliases: subgroup,
            category: category
        ))
    }
    guard !parsed.isEmpty else { throw GeneratorError.invalidUnicodeData }

    var baseRows: [String: ParsedEmoji] = [:]
    var baseOrder: [String] = []
    var toneVariants: [String: [String: String]] = [:]
    for emoji in parsed {
        if emoji.hasSkinToneModifier {
            if let tone = emoji.skinTone {
                toneVariants[emoji.baseKey, default: [:]][tone] = emoji.value
            }
        } else {
            if baseRows[emoji.baseKey] == nil { baseOrder.append(emoji.baseKey) }
            baseRows[emoji.baseKey] = emoji
        }
    }

    let items = baseOrder.compactMap { key -> CatalogItem? in
        guard let emoji = baseRows[key] else { return nil }
        return CatalogItem(
            value: emoji.value,
            name: emoji.name,
            aliases: emoji.aliases,
            category: emoji.category,
            skinToneVariants: toneVariants[key] ?? [:],
            shortcodes: emoji.shortcodeKeys.lazy.compactMap { shortcodes[$0] }.first ?? []
        )
    }
    let catalog = Catalog(
        unicodeVersion: unicodeVersion,
        sourceEntryCount: parsed.count,
        items: items
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(catalog)
    data.append(0x0A)
    try data.write(to: outputURL, options: .atomic)
}

do {
    try generate()
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
