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
        let isFailed: Bool
    }

    /// A file's ring while it shows: until storage has every file of the
    /// send, or once its upload failed.
    func activeUploadRing(for attachmentID: String, uploads: AttachmentUploadProgressStore?, nonce: String?) -> UploadRing? {
        guard let ring = uploadRings.first(where: { $0.attachmentID == attachmentID }) else { return nil }
        return ring.isFailed || uploads?.isUploading(nonce: nonce, attachmentID: attachmentID) == true ? ring : nil
    }

    static func uploadRings(for regions: [AttachmentRegion], isInBubble: Bool, isFailed: Bool) -> [UploadRing] {
        regions.map { region in
            let attachment = region.attachment
            guard attachment.mediaKind.isVisual else {
                let card = NativeTimelineFileCard(frame: region.frame, attachment: attachment, isInBubble: isInBubble)
                return UploadRing(attachmentID: attachment.id, frame: card.buttonFrame, mediaFrame: nil, isFailed: isFailed)
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
/// media and spoiler cover, which the row's own painting would sit
/// beneath, so its control takes its own clicks.
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

    private var isHovered = false {
        didSet { cancelMark.opacity = isHovered && !isFailed ? 1 : 0 }
    }

    /// Cancels the file, or retries its failed send.
    var activate: (() -> Void)?

    var isFailed = false {
        didSet {
            ring.isHidden = isFailed
            // A file card paints a failed upload's Retry in its own button.
            retry.isHidden = !isFailed || !dimsMedia
            cancelMark.opacity = isHovered && !isFailed ? 1 : 0
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

    /// The ring's control: centred over media, or the file card's button.
    private var controlFrame: CGRect {
        guard dimsMedia else { return bounds }
        let side = AttachmentUploadRing.diameter + InterfaceScale.metric(8)
        return CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // A ring fading out no longer acts.
        guard let superview, activate != nil else { return nil }
        return controlFrame.contains(convert(point, from: superview)) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard controlFrame.contains(convert(event.locationInWindow, from: nil)) else { return }
        activate?()
    }

    override func resetCursorRects() {
        guard activate != nil else { return }
        addCursorRect(controlFrame, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: controlFrame, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }

    override func mouseExited(with event: NSEvent) { isHovered = false }

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
        // Rings exist only for sends the store tracks.
        guard uploads.tracksAnySend || !uploadRings.isEmpty else { return }
        var shown = Set<UploadRingKey>()
        var visibleRows = Set<NativeMessageTimelineItem.Identifier>()
        forEachDisplayedRow(in: visibleRect) { index in
            let layout = layouts[index]
            guard !layout.uploadRings.isEmpty,
                  !hidesRowForSendTransition(items[index].identifier),
                  let message = items[index].messageRow?.message,
                  let nonce = message.nonce
            else { return }
            visibleRows.insert(items[index].identifier)
            let origin = displayedRowOrigin(at: index)
            for ring in layout.uploadRings
            where layout.activeUploadRing(for: ring.attachmentID, uploads: uploads, nonce: nonce) != nil {
                if hidesUploadRing(ring, of: message) { continue }
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
                view.activate = { [weak self] in self?.activateUploadRing(ring, of: message) }
                view.fraction = uploads.fraction(nonce: nonce, attachmentID: ring.attachmentID)
            }
        }
        for (key, view) in uploadRings where !shown.contains(key) {
            uploadRings[key] = nil
            view.activate = nil
            window?.invalidateCursorRects(for: view)
            // Only a finished upload in a row that stays put fades out; a ring
            // whose row scrolled away or is flying leaves at once.
            guard visibleRows.contains(key.row) else {
                view.removeFromSuperview()
                continue
            }
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
        return isOutgoing ? .sakuraCordAccentColor : .white
    }

    /// Retries a failed send, or cancels the file still uploading.
    func activateUploadRing(_ ring: NativeTimelineRowLayout.UploadRing, of message: Message) {
        if ring.isFailed {
            actions?.retry(message)
        } else {
            model?.cancelAttachmentUpload(ring.attachmentID, of: message)
        }
    }

    func removeUploadRings() {
        // Including rings still fading out, which no longer have a key.
        for view in subviews where view is NativeTimelineUploadRingView {
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
            guard let attachment = message.attachments.first(where: { $0.id == ring.attachmentID }),
                  layout.activeUploadRing(for: ring.attachmentID, uploads: model?.attachmentUploads, nonce: message.nonce) != nil
            else { continue }
            children.append(accessibilityElement(
                role: .button,
                label: ring.isFailed
                    ? String(localized: "Retry sending \(attachment.filename)")
                    : String(localized: "Cancel upload of \(attachment.filename)"),
                value: ring.isFailed ? String(localized: "Upload failed") : String(localized: "Uploading"),
                frame: accessibilityChildFrame(ring.frame, rowIndex: rowIndex),
                parent: parent
            ) { [weak self] in
                self?.activateUploadRing(ring, of: message)
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
