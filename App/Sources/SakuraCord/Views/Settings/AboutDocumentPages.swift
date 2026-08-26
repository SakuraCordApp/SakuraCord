import AppKit
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
                                AboutChangelogRow(
                                    displayName: release.displayName,
                                    headline: release.announcementHeadline,
                                    systemImage: release.releaseTrack.systemImage
                                )
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
        AboutDocumentDetailPage(document: release.renderedGithubDescription)
            .navigationTitle(release.displayName)
    }
}

private struct AboutAcknowledgementPage: View {
    let acknowledgement: AboutAcknowledgement

    var body: some View {
        AboutDocumentDetailPage(document: acknowledgement.renderedMarkdown)
            .navigationTitle(acknowledgement.title)
    }
}

private struct AboutChangelogRow: View {
    let displayName: String
    let headline: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.headline)

                Text(headline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AboutDocumentDetailPage: View {
    let document: AttributedString

    var body: some View {
        ScrollView {
            AboutMarkdownTextView(document: document)
                .frame(maxWidth: .infinity)
                .padding(32)
                .frame(maxWidth: 784)
                .frame(maxWidth: .infinity)
        }
    }
}

private struct AboutMarkdownTextView: NSViewRepresentable {
    let document: AttributedString

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: 0,
        ]
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor.selectedTextBackgroundColor,
            .foregroundColor: NSColor.selectedTextColor,
        ]
        textView.textStorage?.setAttributedString(
            AboutMarkdownAttributedText.make(document)
        )
        context.coordinator.document = document
        return textView
    }

    func updateNSView(
        _ textView: NSTextView,
        context: Context
    ) {
        guard context.coordinator.document != document else { return }

        let selectedRange = textView.selectedRange()
        let rendered = AboutMarkdownAttributedText.make(document)
        textView.textStorage?.setAttributedString(rendered)
        textView.setSelectedRange(
            NSIntersectionRange(
                selectedRange,
                NSRange(location: 0, length: rendered.length)
            )
        )
        textView.invalidateIntrinsicContentSize()
        context.coordinator.document = document
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView textView: NSTextView,
        context: Context
    ) -> CGSize? {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else { return nil }
        let width = proposal.width ?? 720
        guard width.isFinite,
              width > 0
        else { return nil }

        textView.frame.size.width = width
        textContainer.containerSize = NSSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: textContainer)
        return CGSize(
            width: width,
            height: ceil(layoutManager.usedRect(for: textContainer).height)
        )
    }

    final class Coordinator {
        var document: AttributedString?
    }
}

@MainActor
enum AboutMarkdownAttributedText {
    private enum BlockKind: Equatable {
        case paragraph
        case heading(level: Int)
        case listItem(ordinal: Int, isOrdered: Bool, depth: Int)
        case quote(depth: Int)
        case code
        case tableRow(isHeader: Bool)
        case thematicBreak
    }

    private struct RunContext {
        let identity: Int
        let kind: BlockKind
        let tableColumn: Int?
    }

    static func make(_ document: AttributedString) -> NSAttributedString {
        let output = NSMutableAttributedString()
        var blockIdentity: Int?
        var blockKind: BlockKind = .paragraph
        var block = NSMutableAttributedString()
        var tableColumn: Int?

        func flushBlock() {
            guard block.length > 0 || blockKind == .thematicBreak else { return }
            append(block, kind: blockKind, to: output)
            block = NSMutableAttributedString()
            tableColumn = nil
        }

        for run in document.runs {
            let context = context(for: run.presentationIntent)
            if blockIdentity != context.identity {
                flushBlock()
                blockIdentity = context.identity
                blockKind = context.kind
            }

            if case .tableRow = blockKind,
               let nextColumn = context.tableColumn,
               let tableColumn,
               nextColumn != tableColumn
            {
                block.append(NSAttributedString(string: "\t"))
            }
            tableColumn = context.tableColumn

            block.append(
                styledRun(
                    String(document[run.range].characters),
                    inlineIntent: run.inlinePresentationIntent,
                    link: run.link,
                    blockKind: blockKind
                )
            )
        }
        flushBlock()

        if output.string.hasSuffix("\n") {
            output.deleteCharacters(
                in: NSRange(location: output.length - 1, length: 1)
            )
        }
        return output
    }

    private static func context(
        for presentationIntent: PresentationIntent?
    ) -> RunContext {
        guard let presentationIntent else {
            return RunContext(identity: 0, kind: .paragraph, tableColumn: nil)
        }
        let components = presentationIntent.components
        if let context = tableContext(in: components) {
            return context
        }
        if let context = listContext(in: components) {
            return context
        }
        if let context = quoteContext(in: components) {
            return context
        }
        return leafContext(in: components)
    }

    private static func tableContext(
        in components: [PresentationIntent.IntentType]
    ) -> RunContext? {
        if let row = components.first(where: { component in
            switch component.kind {
            case .tableHeaderRow, .tableRow: true
            default: false
            }
        }) {
            let isHeader = if case .tableHeaderRow = row.kind { true } else { false }
            let column = components.first(where: { component in
                if case .tableCell = component.kind { true } else { false }
            }).flatMap { component in
                if case let .tableCell(columnIndex) = component.kind {
                    columnIndex
                } else {
                    nil
                }
            }
            return RunContext(
                identity: row.identity,
                kind: .tableRow(isHeader: isHeader),
                tableColumn: column
            )
        }
        return nil
    }

    private static func listContext(
        in components: [PresentationIntent.IntentType]
    ) -> RunContext? {
        if let item = components.first(where: { component in
            if case .listItem = component.kind { true } else { false }
        }), case let .listItem(ordinal) = item.kind {
            let isOrdered = components.contains { component in
                if case .orderedList = component.kind { true } else { false }
            }
            let depth = max(
                0,
                components.count(where: { component in
                    switch component.kind {
                    case .orderedList, .unorderedList: true
                    default: false
                    }
                }) - 1
            )
            return RunContext(
                identity: item.identity,
                kind: .listItem(
                    ordinal: ordinal,
                    isOrdered: isOrdered,
                    depth: depth
                ),
                tableColumn: nil
            )
        }
        return nil
    }

    private static func quoteContext(
        in components: [PresentationIntent.IntentType]
    ) -> RunContext? {
        let quoteDepth = components.count { component in
            if case .blockQuote = component.kind { true } else { false }
        }
        if quoteDepth > 0,
           let paragraph = components.first(where: { component in
               if case .paragraph = component.kind { true } else { false }
           })
        {
            return RunContext(
                identity: paragraph.identity,
                kind: .quote(depth: quoteDepth - 1),
                tableColumn: nil
            )
        }
        return nil
    }

    private static func leafContext(
        in components: [PresentationIntent.IntentType]
    ) -> RunContext {
        guard let leaf = components.first else {
            return RunContext(identity: 0, kind: .paragraph, tableColumn: nil)
        }
        let kind = switch leaf.kind {
        case let .header(level): BlockKind.heading(level: level)
        case .codeBlock: BlockKind.code
        case .thematicBreak: BlockKind.thematicBreak
        default: BlockKind.paragraph
        }
        return RunContext(
            identity: leaf.identity,
            kind: kind,
            tableColumn: nil
        )
    }

    private static func styledRun(
        _ text: String,
        inlineIntent: InlinePresentationIntent?,
        link: URL?,
        blockKind: BlockKind
    ) -> NSAttributedString {
        let inlineIntent = inlineIntent ?? []
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(for: blockKind, inlineIntent: inlineIntent),
            .foregroundColor: NSColor.labelColor,
        ]
        if inlineIntent.contains(.strikethrough) {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if inlineIntent.contains(.code) {
            attributes[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.12)
        }
        if let link {
            attributes[.link] = link
        }
        return NSAttributedString(string: text, attributes: attributes)
    }

    private static func font(
        for blockKind: BlockKind,
        inlineIntent: InlinePresentationIntent
    ) -> NSFont {
        let size: CGFloat
        let defaultWeight: NSFont.Weight
        switch blockKind {
        case let .heading(level):
            size = switch level {
            case 1: 22
            case 2: 17
            case 3: 15
            default: NSFont.systemFontSize
            }
            defaultWeight = .semibold
        case .tableRow(isHeader: true):
            size = NSFont.smallSystemFontSize
            defaultWeight = .semibold
        case .code, .tableRow:
            size = NSFont.smallSystemFontSize
            defaultWeight = .regular
        default:
            size = NSFont.systemFontSize
            defaultWeight = .regular
        }

        let isStrong = inlineIntent.contains(.stronglyEmphasized)
        let isCode = inlineIntent.contains(.code) || blockKind == .code
        var font = isCode
            ? NSFont.monospacedSystemFont(ofSize: size, weight: isStrong ? .semibold : defaultWeight)
            : NSFont.systemFont(ofSize: size, weight: isStrong ? .semibold : defaultWeight)
        if inlineIntent.contains(.emphasized) {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }

    private static func append(
        _ content: NSAttributedString,
        kind: BlockKind,
        to output: NSMutableAttributedString
    ) {
        let blockStart = output.length
        switch kind {
        case let .listItem(ordinal, isOrdered, depth):
            let prefix = isOrdered ? "\(ordinal).\t" : "•\t"
            output.append(
                NSAttributedString(
                    string: String(repeating: "\t", count: depth) + prefix,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]
                )
            )
            output.append(content)
        case let .quote(depth):
            output.append(
                NSAttributedString(
                    string: String(repeating: "\t", count: depth) + "│\t",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                        .foregroundColor: NSColor.tertiaryLabelColor,
                    ]
                )
            )
            output.append(content)
        case .thematicBreak:
            output.append(
                NSAttributedString(
                    string: "────────",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                        .foregroundColor: NSColor.separatorColor,
                    ]
                )
            )
        default:
            output.append(content)
        }
        output.append(NSAttributedString(string: "\n"))

        let paragraphStyle = paragraphStyle(for: kind)
        output.addAttribute(
            .paragraphStyle,
            value: paragraphStyle,
            range: NSRange(
                location: blockStart,
                length: output.length - blockStart
            )
        )
    }

    private static func paragraphStyle(for kind: BlockKind) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.paragraphSpacing = 10

        switch kind {
        case let .heading(level):
            style.paragraphSpacingBefore = level == 1 ? 0 : 8
            style.paragraphSpacing = level == 1 ? 12 : 8
        case let .listItem(_, _, depth):
            let indentation = CGFloat(depth) * 18
            style.firstLineHeadIndent = indentation
            style.headIndent = indentation + 20
            style.tabStops = [NSTextTab(textAlignment: .left, location: indentation + 20)]
            style.paragraphSpacing = 4
        case let .quote(depth):
            let indentation = CGFloat(depth) * 18
            style.firstLineHeadIndent = indentation
            style.headIndent = indentation + 18
            style.tabStops = [NSTextTab(textAlignment: .left, location: indentation + 18)]
        case .code:
            style.headIndent = 12
            style.firstLineHeadIndent = 12
            style.tailIndent = -12
            style.paragraphSpacing = 12
        case .tableRow:
            style.tabStops = [
                NSTextTab(textAlignment: .left, location: 260),
                NSTextTab(textAlignment: .left, location: 520),
            ]
            style.paragraphSpacing = 4
        case .thematicBreak:
            style.paragraphSpacing = 10
        case .paragraph:
            break
        }
        return style
    }
}
