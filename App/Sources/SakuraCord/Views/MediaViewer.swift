import AppKit
import SwiftUI

struct MediaViewer: View {
    let presentation: NativeTimelineMediaViewerPresentation
    let isVisible: Bool
    let transitionSourceFrame: CGRect?
    let transitionSourceVisibleFrame: CGRect?
    let close: () -> Void
    let closeInteractively: () -> Void
    @State private var interaction: MediaViewerInteractionModel
    @State private var feedbackTask: Task<Void, Never>?
    @FocusState private var keyboardNavigationIsFocused: Bool

    init(
        presentation: NativeTimelineMediaViewerPresentation,
        isVisible: Bool = true,
        transitionSourceFrame: CGRect? = nil,
        transitionSourceVisibleFrame: CGRect? = nil,
        close: @escaping () -> Void,
        closeInteractively: @escaping () -> Void
    ) {
        self.presentation = presentation
        self.isVisible = isVisible
        self.transitionSourceFrame = transitionSourceFrame
        self.transitionSourceVisibleFrame = transitionSourceVisibleFrame
        self.close = close
        self.closeInteractively = closeInteractively
        _interaction = State(
            initialValue: MediaViewerInteractionModel(
                itemCount: presentation.items.count,
                selection: presentation.selection
            )
        )
    }

    var body: some View {
        let item = presentation.items[interaction.selection]
        let transitionSource = presentation.transitionSource.flatMap { source in
            source.itemID == item.id
                && transitionSourceFrame != nil
                && transitionSourceVisibleFrame != nil
                ? source
                : nil
        }
        let usesSourceTransition = transitionSource != nil

        GlassEffectContainer(spacing: 12) {
            GeometryReader { proxy in
                ZStack {
                    if presentation.transitionSource != nil,
                       let transitionSourceVisibleFrame
                    {
                        Color(nsColor: .windowBackgroundColor)
                            .frame(
                                width: transitionSourceVisibleFrame.width,
                                height: transitionSourceVisibleFrame.height
                            )
                            .position(
                                x: transitionSourceVisibleFrame.midX,
                                y: transitionSourceVisibleFrame.midY
                            )
                            .allowsHitTesting(false)
                    }

                    MediaViewerBackdrop(
                        isVisible: isVisible,
                        interaction: interaction,
                        close: close
                    )

                    MediaViewerStage(
                        item: item,
                        isVisible: isVisible,
                        transitionSource: transitionSource,
                        transitionSourceFrame: transitionSourceFrame,
                        transitionSourceVisibleFrame:
                            transitionSourceVisibleFrame,
                        horizontalInset: 66,
                        topInset: MediaViewerTopChromeMetrics.mediaTopInset,
                        bottomInset: presentation.items.count > 1 ? 82 : 14,
                        interaction: interaction,
                        finishPinchDismissal: finishPinchDismissal,
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
                    .modifier(
                        MediaViewerStagePresentationEffect(
                            isVisible: isVisible,
                            usesSourceTransition: usesSourceTransition,
                            interaction: interaction
                        )
                    )

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
                    .modifier(
                        MediaViewerChromePresentationEffect(
                            isVisible: isVisible,
                            hiddenOffsetY: -10,
                            interaction: interaction
                        )
                    )

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
                    .modifier(
                        MediaViewerChromePresentationEffect(
                            isVisible: isVisible,
                            hiddenOffsetY: -10,
                            interaction: interaction
                        )
                    )

                    if presentation.items.count > 1 {
                        MediaViewerNavigationButtons(
                            canMoveBackward: interaction.canMoveBackward,
                            canMoveForward: interaction.canMoveForward,
                            moveBackward: { move(-1) },
                            moveForward: { move(1) }
                        )
                        .padding(.horizontal, 18)
                        .modifier(
                            MediaViewerChromePresentationEffect(
                                isVisible: isVisible,
                                hiddenOffsetY: 0,
                                interaction: interaction
                            )
                        )

                        MediaViewerThumbnailStrip(
                            items: presentation.items,
                            selection: interaction.selection,
                            maximumWidth: max(
                                120,
                                min(760, proxy.size.width - 180)
                            ),
                            select: select
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 14)
                        .modifier(
                            MediaViewerChromePresentationEffect(
                                isVisible: isVisible,
                                hiddenOffsetY: 14,
                                interaction: interaction
                            )
                        )
                    }

                    if let feedback = interaction.feedback {
                        MediaViewerFeedbackPill(message: feedback.message)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .padding(.bottom, presentation.items.count > 1 ? 86 : 22)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
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

    private func finishPinchDismissal(magnification: CGFloat) -> Bool {
        let committed = interaction.shouldCommitPinchDismissal(
            magnification: magnification
        )
        if committed {
            closeInteractively()
        } else {
            withAnimation(
                .snappy(
                    duration:
                        MediaViewerTransitionTiming
                            .interactiveCancellationDuration,
                    extraBounce: 0.04
                )
            ) {
                interaction.cancelPinchDismissal()
            }
        }
        return committed
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

private struct MediaViewerBackdrop: View {
    let isVisible: Bool
    let interaction: MediaViewerInteractionModel
    let close: () -> Void

    var body: some View {
        let presentationProgress = isVisible
            ? 1 - interaction.pinchDismissalProgress
            : 0

        Color.black.opacity(
            WindowModalVisualStyle.mediaViewerBackgroundDimmingOpacity
                * presentationProgress
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: close)
    }
}

private struct MediaViewerStagePresentationEffect: ViewModifier {
    let isVisible: Bool
    let usesSourceTransition: Bool
    let interaction: MediaViewerInteractionModel

    func body(content: Content) -> some View {
        let presentationProgress = isVisible
            ? 1 - interaction.pinchDismissalProgress
            : 0
        content
            .scaleEffect(
                usesSourceTransition
                    ? 1
                    : 0.965 + presentationProgress * 0.035
            )
            .opacity(usesSourceTransition ? 1 : presentationProgress)
    }
}

private struct MediaViewerChromePresentationEffect: ViewModifier {
    let isVisible: Bool
    let hiddenOffsetY: CGFloat
    let interaction: MediaViewerInteractionModel

    func body(content: Content) -> some View {
        let presentationProgress = isVisible
            ? 1 - interaction.pinchDismissalProgress
            : 0
        content
            .offset(y: hiddenOffsetY * (1 - presentationProgress))
            .opacity(presentationProgress)
            .scaleEffect(0.975 + presentationProgress * 0.025)
    }
}
