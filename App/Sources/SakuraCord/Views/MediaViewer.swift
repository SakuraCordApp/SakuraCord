import AppKit
import SwiftUI

struct MediaViewer: View {
    let presentation: NativeTimelineMediaViewerPresentation
    let isVisible: Bool
    let close: () -> Void
    @State private var interaction: MediaViewerInteractionModel
    @State private var feedbackTask: Task<Void, Never>?
    @FocusState private var keyboardNavigationIsFocused: Bool

    init(
        presentation: NativeTimelineMediaViewerPresentation,
        isVisible: Bool = true,
        close: @escaping () -> Void
    ) {
        self.presentation = presentation
        self.isVisible = isVisible
        self.close = close
        _interaction = State(
            initialValue: MediaViewerInteractionModel(
                itemCount: presentation.items.count,
                selection: presentation.selection
            )
        )
    }

    var body: some View {
        let item = presentation.items[interaction.selection]

        GlassEffectContainer(spacing: 12) {
            GeometryReader { proxy in
                ZStack {
                    Color.black.opacity(0.91)
                        .opacity(isVisible ? 1 : 0)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: close)

                    MediaViewerStage(
                        item: item,
                        scale: interaction.scale,
                        offset: interaction.offset,
                        horizontalInset: 66,
                        topInset: MediaViewerTopChromeMetrics.mediaTopInset,
                        bottomInset: presentation.items.count > 1 ? 82 : 14,
                        commitScale: interaction.commitScale,
                        commitOffset: interaction.commitOffset,
                        toggleZoom: interaction.toggleZoom,
                        open: {
                            MediaViewerActionService.openInBrowser(item.url)
                        },
                        imageContextMenuActions: MediaImageContextMenuActions(
                            copyImage: { copyImage(item) },
                            saveImage: { save(item) },
                            copyLink: { copyLink(item) },
                            openLink: {
                                MediaViewerActionService.openInBrowser(item.url)
                            }
                        )
                    )
                    .id(item.id)
                    .scaleEffect(isVisible ? 1 : 0.965)
                    .opacity(isVisible ? 1 : 0)

                    MediaViewerHeader(
                        authorName: presentation.authorName,
                        authorAvatarURL: presentation.authorAvatarURL,
                        timestamp: presentation.timestamp,
                        selection: interaction.selection,
                        itemCount: presentation.items.count
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.leading, 72)
                    .padding(
                        .top,
                        MediaViewerTopChromeMetrics.outerPadding
                    )
                    .offset(y: isVisible ? 0 : -10)
                    .opacity(isVisible ? 1 : 0)

                    MediaViewerTopControls(
                        item: item,
                        isSaving: interaction.isSaving,
                        copyImage: { copyImage(item) },
                        copyLink: { copyLink(item) },
                        copyAttachmentID: { copyAttachmentID(item) },
                        save: { save(item) },
                        open: {
                            MediaViewerActionService.openInBrowser(item.url)
                        },
                        close: close
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.trailing, 16)
                    .padding(
                        .top,
                        MediaViewerTopChromeMetrics.outerPadding
                    )
                    .offset(y: isVisible ? 0 : -10)
                    .opacity(isVisible ? 1 : 0)

                    if presentation.items.count > 1 {
                        MediaViewerNavigationButtons(
                            canMoveBackward: interaction.canMoveBackward,
                            canMoveForward: interaction.canMoveForward,
                            moveBackward: { move(-1) },
                            moveForward: { move(1) }
                        )
                        .padding(.horizontal, 18)
                        .opacity(isVisible ? 1 : 0)

                        MediaViewerThumbnailStrip(
                            items: presentation.items,
                            selection: interaction.selection,
                            select: select
                        )
                        .frame(
                            maxWidth: min(760, proxy.size.width * 0.72),
                            maxHeight: .infinity,
                            alignment: .bottom
                        )
                        .padding(.bottom, 14)
                        .offset(y: isVisible ? 0 : 14)
                        .opacity(isVisible ? 1 : 0)
                    }

                    if let feedback = interaction.feedback {
                        MediaViewerFeedbackPill(message: feedback.message)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .padding(.bottom, presentation.items.count > 1 ? 86 : 22)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.22), value: isVisible)
            }
        }
        .ignoresSafeArea()
        .focusable()
        .focused($keyboardNavigationIsFocused)
        .focusEffectDisabled()
        .allowsHitTesting(isVisible)
        .onExitCommand(perform: close)
        .onKeyPress(phases: .down) { press in
            handleKeyPress(press)
        }
        .task {
            await Task.yield()
            keyboardNavigationIsFocused = true
        }
        .onDisappear {
            feedbackTask?.cancel()
            feedbackTask = nil
        }
        .alert(
            "Media action failed",
            isPresented: Binding(
                get: { interaction.errorMessage != nil },
                set: { if !$0 { interaction.errorMessage = nil } }
            )
        ) {
            Button("OK") { interaction.errorMessage = nil }
        } message: {
            Text(interaction.errorMessage ?? "Unknown error")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Media viewer, item \(interaction.selection + 1) of \(presentation.items.count)"
        )
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .leftArrow:
            move(-1)
            return .handled
        case .rightArrow:
            move(1)
            return .handled
        default:
            return .ignored
        }
    }

    private func move(_ delta: Int) {
        guard interaction.move(delta) else { return }
        announceSelection()
    }

    private func select(_ index: Int) {
        guard interaction.select(index) else { return }
        announceSelection()
    }

    private func announceSelection() {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement:
                    "Item \(interaction.selection + 1) of \(presentation.items.count)"
            ]
        )
    }

    private func copyImage(_ item: RichMediaItem) {
        Task {
            do {
                try await MediaViewerActionService.copyImage(from: item.url)
                showFeedback("Image copied")
            } catch {
                interaction.errorMessage = error.localizedDescription
            }
        }
    }

    private func copyLink(_ item: RichMediaItem) {
        MediaViewerActionService.copyText(item.url.absoluteString)
        showFeedback("Media link copied")
    }

    private func copyAttachmentID(_ item: RichMediaItem) {
        MediaViewerActionService.copyText(item.id)
        showFeedback("Attachment ID copied")
    }

    private func save(_ item: RichMediaItem) {
        guard !interaction.isSaving else { return }
        interaction.isSaving = true
        Task {
            defer { interaction.isSaving = false }
            do {
                if let destination = try await MediaViewerActionService.save(item) {
                    showFeedback("Saved \(destination.lastPathComponent)")
                }
            } catch {
                interaction.errorMessage = error.localizedDescription
            }
        }
    }

    private func showFeedback(_ message: String) {
        feedbackTask?.cancel()
        withAnimation(.snappy(duration: 0.22)) {
            interaction.feedback = MediaViewerFeedback(message: message)
        }
        feedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                interaction.feedback = nil
            }
        }
    }
}
