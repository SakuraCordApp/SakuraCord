import AppKit
import SakuraCordModels

extension NativeTimelineRowLayout {
    /// A local send's file still uploading, or whose upload failed. Its ring
    /// sits over an image or video, which it dims, or in a file card's
    /// button. The control cancels the file, or after a failure retries the
    /// send.
    struct UploadRing: Equatable {
        let attachmentID: String
        /// The control the ring draws in.
        let frame: CGRect
        /// The image or video under the ring.
        let mediaFrame: CGRect?
        /// An audio card's smaller chip, which rings in the accent colour.
        var isAudio = false
        let isFailed: Bool
    }

    static func uploadRings(for regions: [AttachmentRegion], isInBubble: Bool, isFailed: Bool) -> [UploadRing] {
        regions.map { region in
            let attachment = region.attachment
            guard attachment.mediaKind.isVisual else {
                let card = NativeTimelineFileCard(
                    frame: region.frame, attachment: attachment, isInBubble: isInBubble,
                    isAudio: attachment.mediaKind == .audio
                )
                return UploadRing(
                    attachmentID: attachment.id, frame: card.buttonFrame, mediaFrame: nil,
                    isAudio: card.isAudio, isFailed: isFailed
                )
            }
            let side = AttachmentUploadRing.diameter + InterfaceScale.metric(8)
            return UploadRing(
                attachmentID: attachment.id,
                frame: CGRect(x: region.frame.midX - side / 2, y: region.frame.midY - side / 2, width: side, height: side),
                mediaFrame: region.frame,
                isFailed: isFailed
            )
        }
    }
}

/// A file's upload over its row: the dim over an image or video and the
/// ring, with a cancel mark under the pointer, or Retry once it failed.
/// Progress moves only the ring's stroke. It sits above the row's animated
/// media, which the row's own painting would sit beneath.
final class NativeTimelineUploadRingView: NSView {
    private let dimsMedia: Bool
    private let dim = CALayer()
    private let ring = AttachmentUploadRingLayer()
    private let cancelMark = CAShapeLayer()
    private let retry = CALayer()

    var fraction: Double {
        get { ring.fraction }
        set { ring.fraction = newValue }
    }

    var isCancelHovered = false {
        didSet { cancelMark.opacity = isCancelHovered && !isFailed ? 1 : 0 }
    }

    var isFailed = false {
        didSet {
            ring.isHidden = isFailed
            retry.isHidden = !isFailed
            cancelMark.opacity = isCancelHovered && !isFailed ? 1 : 0
        }
    }

    init(dimsMedia: Bool) {
        self.dimsMedia = dimsMedia
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        // Media overlays installed later, such as a GIF that finishes
        // decoding, would otherwise stack above it.
        layer?.zPosition = 1
        if dimsMedia {
            dim.backgroundColor = .black
            dim.opacity = Float(AttachmentUploadRing.dimOpacity)
            dim.cornerCurve = .continuous
            dim.cornerRadius = NativeTimelineRowPainter.attachmentCornerRadius
            layer?.addSublayer(dim)
        }
        layer?.addSublayer(ring)
        let side = InterfaceScale.metric(9)
        let mark = CGMutablePath()
        mark.move(to: .zero)
        mark.addLine(to: CGPoint(x: side, y: side))
        mark.move(to: CGPoint(x: 0, y: side))
        mark.addLine(to: CGPoint(x: side, y: 0))
        cancelMark.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        cancelMark.path = mark
        cancelMark.lineWidth = InterfaceScale.metric(2)
        cancelMark.lineCap = .round
        cancelMark.opacity = 0
        layer?.addSublayer(cancelMark)
        retry.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        retry.contents = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: InterfaceScale.metric(14), weight: .semibold).applying(.init(paletteColors: [.white])))
        retry.contentsGravity = .center
        retry.isHidden = true
        layer?.addSublayer(retry)
        setColor(.white)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dim.frame = bounds
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        // Over media the ring keeps its size; in a file card's button it
        // fills the button as the download ring does.
        let diameter = dimsMedia ? AttachmentUploadRing.diameter : bounds.width - 2 * InterfaceScale.metric(4)
        ring.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        ring.position = center
        cancelMark.position = center
        let control = AttachmentUploadRing.diameter + InterfaceScale.metric(8)
        retry.bounds = CGRect(x: 0, y: 0, width: control, height: control)
        retry.cornerRadius = control / 2
        retry.position = center
        retry.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    func setColor(_ color: NSColor) {
        ring.color = color.cgColor
        cancelMark.strokeColor = color.cgColor
    }
}

extension NativeTimelineCanvasView {
    struct UploadRingKey: Hashable {
        let row: NativeMessageTimelineItem.Identifier
        let attachmentID: String
    }

    /// Shows the live ring of each visible file still uploading. A finished
    /// file's ring fades out, revealing the row beneath.
    func reconcileUploadRings() {
        guard let uploads = model?.attachmentUploads else { return removeUploadRings() }
        var shown = Set<UploadRingKey>()
        forEachDisplayedRow(in: visibleRect) { index in
            let layout = layouts[index]
            guard !layout.uploadRings.isEmpty,
                  !hidesRowForSendTransition(items[index].identifier),
                  let nonce = items[index].messageRow?.message.nonce
            else { return }
            let origin = displayedRowOrigin(at: index)
            // A file card shows a failed upload's Retry in its own button.
            for ring in layout.uploadRings where ring.isFailed
                ? ring.mediaFrame != nil
                : uploads.isUploading(nonce: nonce, attachmentID: ring.attachmentID) {
                let key = UploadRingKey(row: items[index].identifier, attachmentID: ring.attachmentID)
                shown.insert(key)
                let view = uploadRings[key] ?? {
                    let view = NativeTimelineUploadRingView(dimsMedia: ring.mediaFrame != nil)
                    addSubview(view, positioned: .below, relativeTo: mediaViewerHost)
                    uploadRings[key] = view
                    return view
                }()
                view.frame = (ring.mediaFrame ?? ring.frame).offsetBy(dx: 0, dy: origin)
                view.setColor(Self.uploadRingColor(ring, isOutgoing: layout.bubbleRegion?.isOutgoing == true))
                view.isFailed = ring.isFailed
                view.isCancelHovered = hoveredFooterAction?.kind == .cancelUpload(attachmentID: ring.attachmentID)
                view.fraction = uploads.fraction(nonce: nonce, attachmentID: ring.attachmentID)
            }
        }
        for (key, view) in uploadRings where !shown.contains(key) {
            uploadRings[key] = nil
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                view.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated { view.removeFromSuperview() }
            }
        }
    }

    /// White over media and in a file card's accent button; a file card's
    /// colours invert in an outgoing bubble, as its download ring's do.
    static func uploadRingColor(_ ring: NativeTimelineRowLayout.UploadRing, isOutgoing: Bool) -> NSColor {
        guard ring.mediaFrame == nil else { return .white }
        return ring.isAudio != isOutgoing ? .sakuraCordAccentColor : .white
    }

    func removeUploadRings() {
        for view in uploadRings.values {
            view.removeFromSuperview()
        }
        uploadRings.removeAll()
    }

    /// Each file stays labelled with its upload state, and its ring with
    /// what it does.
    func appendUploadAccessibility(
        to children: inout [Any],
        message: Message,
        layout: NativeTimelineRowLayout,
        rowIndex: Int,
        parent: NSAccessibilityElement
    ) {
        for ring in layout.uploadRings {
            guard let attachment = message.attachments.first(where: { $0.id == ring.attachmentID }) else { continue }
            let isUploading = model?.attachmentUploads.isUploading(nonce: message.nonce, attachmentID: ring.attachmentID) == true
            guard ring.isFailed || isUploading else { continue }
            children.append(accessibilityElement(
                role: .button,
                label: ring.isFailed
                    ? String(localized: "Retry sending \(attachment.filename)")
                    : String(localized: "Cancel upload of \(attachment.filename)"),
                value: ring.isFailed ? String(localized: "Upload failed") : String(localized: "Uploading"),
                frame: accessibilityChildFrame(ring.frame, rowIndex: rowIndex),
                parent: parent
            ) { [weak self] in
                if ring.isFailed {
                    self?.actions?.retry(message)
                } else {
                    self?.model?.cancelAttachmentUpload(ring.attachmentID, of: message)
                }
                return true
            })
        }
    }

    /// Progress moves only the rings. Once a file is stored its ring leaves
    /// and its row repaints, giving a file card's button its glyph back.
    @objc func attachmentUploadsDidChange(_ notification: Notification) {
        guard notification.object as AnyObject === model?.attachmentUploads,
              let nonce = notification.userInfo?[AttachmentUploadProgressStore.nonceKey] as? String
        else { return }
        let endsCancellation = notification.userInfo?[AttachmentUploadProgressStore.endsCancellationKey] as? Bool == true
        let shown = Set(uploadRings.keys)
        reconcileUploadRings()
        guard endsCancellation || !shown.isSubset(of: uploadRings.keys) else { return }
        // Cached bitmaps outlive navigation, so drop this send's row wherever it was cached.
        for (identifier, cached) in bitmapCache where cached.item.messageRow?.message.nonce == nonce {
            invalidateBitmap(identifier)
        }
        forEachDisplayedRow(in: visibleRect) { index in
            if items[index].messageRow?.message.nonce == nonce { setNeedsDisplay(rowFrame(at: index)) }
        }
        if endsCancellation {
            window?.invalidateCursorRects(for: self)
            reconcileAccessibilityProxiesIfActive()
        }
    }
}
