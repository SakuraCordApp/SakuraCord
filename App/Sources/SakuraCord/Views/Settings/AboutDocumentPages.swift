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
                SettingsForm {
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
                SettingsForm {
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
        HStack(spacing: InterfaceScale.metric(12)) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: InterfaceScale.metric(18))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: InterfaceScale.metric(2)) {
                Text(displayName)
                    .font(.interface(.headline))

                Text(headline)
                    .font(.interface(.caption))
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
                .padding(InterfaceScale.metric(32))
                .frame(maxWidth: InterfaceScale.metric(784))
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
        let textView = MarkdownDocumentText.makeTextView()
        textView.isRichText = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.applySakuraCordTextSelectionAppearance()
        textView.delegate = context.coordinator
        return textView
    }

    func updateNSView(
        _ textView: NSTextView,
        context: Context
    ) {
        textView.applySakuraCordTextSelectionAppearance()
        let colorScheme = context.environment.colorScheme
        guard context.coordinator.document != document || context.coordinator.colorScheme != colorScheme else { return }

        let selectedRange = textView.selectedRange()
        let rendered = MarkdownDocumentText.make(document, codeBackground: colorScheme == .light ? .light : .dark)
        textView.textStorage?.setAttributedString(rendered)
        textView.setSelectedRange(
            NSIntersectionRange(
                selectedRange,
                NSRange(location: 0, length: rendered.length)
            )
        )
        textView.invalidateIntrinsicContentSize()
        context.coordinator.document = document
        context.coordinator.colorScheme = colorScheme
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

    final class Coordinator: NSObject, NSTextViewDelegate {
        var document: AttributedString?
        var colorScheme: ColorScheme?

        /// Release notes and notices are SakuraCord's own, so their other
        /// links open as the text view opens them.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            MarkdownDocumentText.scrollToAnchor(link, in: textView)
        }
    }
}
