import Foundation
import SwiftUI

struct AboutChangelogPage: View {
    let releaseNotes: [AboutReleaseNotes]

    var body: some View {
        Group {
            if releaseNotes.isEmpty {
                ContentUnavailableView(
                    "Changelog Unavailable",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(
                        "This build does not include SakuraCord’s release notes."
                    )
                )
            } else {
                Form {
                    Section {
                        ForEach(releaseNotes) { release in
                            NavigationLink {
                                AboutReleaseNotesPage(release: release)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(release.tagName)
                                        .font(.headline)
                                    Text("Release notes")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .navigationTitle("Changelog")
    }
}

struct AboutAcknowledgementsPage: View {
    let acknowledgements: [AboutAcknowledgement]

    var body: some View {
        Group {
            if acknowledgements.isEmpty {
                ContentUnavailableView(
                    "Acknowledgements Unavailable",
                    systemImage: "doc.text",
                    description: Text(
                        "This build does not include SakuraCord’s third-party notices."
                    )
                )
            } else {
                Form {
                    Section {
                        ForEach(acknowledgements) { acknowledgement in
                            NavigationLink {
                                AboutAcknowledgementPage(
                                    acknowledgement: acknowledgement
                                )
                            } label: {
                                Text(acknowledgement.title)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .navigationTitle("Third-Party Acknowledgements")
    }

}

private struct AboutReleaseNotesPage: View {
    let release: AboutReleaseNotes

    var body: some View {
        AboutDocumentDetailPage(markdown: release.githubDescription)
            .navigationTitle(release.tagName)
    }
}

private struct AboutAcknowledgementPage: View {
    let acknowledgement: AboutAcknowledgement

    var body: some View {
        AboutDocumentDetailPage(markdown: acknowledgement.markdown)
            .navigationTitle(acknowledgement.title)
    }
}

private struct AboutDocumentDetailPage: View {
    let markdown: String

    var body: some View {
        ScrollView {
            AboutMarkdownDocumentView(markdown: markdown)
                .frame(maxWidth: 720, alignment: .leading)
                .padding(32)
                .frame(maxWidth: .infinity)
        }
        .textSelection(.enabled)
    }
}

private struct AboutMarkdownDocumentView: View {
    let blocks: [AboutMarkdownBlock]

    init(markdown: String) {
        blocks = AboutMarkdownParser.parse(markdown)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { block in
                blockView(block.kind)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: AboutMarkdownBlock.Kind) -> some View {
        switch block {
        case let .heading(level, text):
            Text(inlineMarkdown(text))
                .font(headingFont(level))
                .foregroundStyle(.primary.opacity(0.86))
                .padding(.top, level == 1 ? 4 : 8)

        case let .paragraph(text):
            Text(inlineMarkdown(text))
                .font(.body)
                .foregroundStyle(.primary.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)

        case let .unorderedItem(text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•")
                    .foregroundStyle(.secondary)
                Text(inlineMarkdown(text))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.body)

        case let .orderedItem(marker, text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker)
                    .foregroundStyle(.secondary)
                Text(inlineMarkdown(text))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.body)

        case let .quote(text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(.secondary)
                    .frame(width: 3)
                Text(inlineMarkdown(text))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case let .code(text):
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: .rect(cornerRadius: 8))

        case let .table(rows):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    ForEach(rows.indices, id: \.self) { rowIndex in
                        GridRow {
                            ForEach(rows[rowIndex].indices, id: \.self) { columnIndex in
                                Text(inlineMarkdown(rows[rowIndex][columnIndex]))
                                    .font(
                                        rowIndex == 0
                                            ? .caption.bold()
                                            : .system(.caption, design: .monospaced)
                                    )
                            }
                        }
                    }
                }
                .padding(12)
            }
            .background(.quaternary, in: .rect(cornerRadius: 8))
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.bold()
        case 2: .title3.bold()
        case 3: .headline
        default: .subheadline.bold()
        }
    }

    private func inlineMarkdown(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: source, options: options))
            ?? AttributedString(source)
    }
}

private struct AboutMarkdownBlock: Identifiable {
    enum Kind {
        case heading(level: Int, text: String)
        case paragraph(String)
        case unorderedItem(String)
        case orderedItem(marker: String, text: String)
        case quote(String)
        case code(String)
        case table([[String]])
    }

    let id: Int
    let kind: Kind
}

private enum AboutMarkdownParser {
    static func parse(_ markdown: String) -> [AboutMarkdownBlock] {
        let lines = markdown.components(separatedBy: .newlines)
        var blocks: [AboutMarkdownBlock.Kind] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }
            blocks.append(parseBlock(lines, index: &index))
        }

        return blocks.enumerated().map { offset, kind in
            AboutMarkdownBlock(id: offset, kind: kind)
        }
    }

    private static func parseBlock(
        _ lines: [String],
        index: inout Int
    ) -> AboutMarkdownBlock.Kind {
        let line = lines[index]
        if line.hasPrefix("```") {
            return codeBlock(lines, index: &index)
        }
        if let heading = heading(line) {
            index += 1
            return .heading(level: heading.level, text: heading.text)
        }
        if isTableRow(line) {
            return tableBlock(lines, index: &index)
        }
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            let text = continuedText(
                lines,
                index: &index,
                firstLine: String(line.dropFirst(2))
            )
            return .unorderedItem(text)
        }
        if let ordered = orderedItem(line) {
            let text = continuedText(
                lines,
                index: &index,
                firstLine: ordered.text
            )
            return .orderedItem(marker: ordered.marker, text: text)
        }
        if line.hasPrefix("> ") {
            return quoteBlock(lines, index: &index)
        }
        return .paragraph(
            continuedText(lines, index: &index, firstLine: line)
        )
    }

    private static func codeBlock(
        _ lines: [String],
        index: inout Int
    ) -> AboutMarkdownBlock.Kind {
        index += 1
        var codeLines: [String] = []
        while index < lines.count, !lines[index].hasPrefix("```") {
            codeLines.append(lines[index])
            index += 1
        }
        if index < lines.count { index += 1 }
        return .code(codeLines.joined(separator: "\n"))
    }

    private static func tableBlock(
        _ lines: [String],
        index: inout Int
    ) -> AboutMarkdownBlock.Kind {
        var rows: [[String]] = []
        while index < lines.count, isTableRow(lines[index]) {
            let cells = tableCells(lines[index])
            if !isTableSeparator(cells) {
                rows.append(cells)
            }
            index += 1
        }
        return .table(rows)
    }

    private static func continuedText(
        _ lines: [String],
        index: inout Int,
        firstLine: String
    ) -> String {
        var values = [firstLine]
        index += 1
        while index < lines.count, !isBlockStart(lines[index]) {
            values.append(lines[index])
            index += 1
        }
        return values.joined(separator: " ")
    }

    private static func quoteBlock(
        _ lines: [String],
        index: inout Int
    ) -> AboutMarkdownBlock.Kind {
        var values: [String] = []
        while index < lines.count, lines[index].hasPrefix("> ") {
            values.append(String(lines[index].dropFirst(2)))
            index += 1
        }
        return .quote(values.joined(separator: " "))
    }

    private static func isBlockStart(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
            || line.hasPrefix("```")
            || heading(line) != nil
            || isTableRow(line)
            || line.hasPrefix("- ")
            || line.hasPrefix("* ")
            || line.hasPrefix("> ")
            || orderedItem(line) != nil
    }

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        let prefix = line.prefix { $0 == "#" }
        guard !prefix.isEmpty,
              prefix.count <= 6,
              line.dropFirst(prefix.count).hasPrefix(" ")
        else { return nil }
        return (
            prefix.count,
            String(line.dropFirst(prefix.count + 1))
        )
    }

    private static func orderedItem(_ line: String) -> (marker: String, text: String)? {
        guard let period = line.firstIndex(of: ".") else { return nil }
        let number = line[..<period]
        let remainder = line[line.index(after: period)...]
        guard !number.isEmpty,
              number.allSatisfy(\.isNumber),
              remainder.hasPrefix(" ")
        else { return nil }
        return ("\(number).", String(remainder.dropFirst()))
    }

    private static func isTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("|") && trimmed.hasSuffix("|")
    }

    private static func tableCells(_ line: String) -> [String] {
        line.trimmingCharacters(in: .whitespaces)
            .dropFirst()
            .dropLast()
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isTableSeparator(_ cells: [String]) -> Bool {
        !cells.isEmpty && cells.allSatisfy { cell in
            let value = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return value.count >= 3 && value.allSatisfy { $0 == "-" }
        }
    }
}
