import AppKit
import SwiftUI

private extension NSAttributedString.Key {
    static let selectionFieldTokenIdentifier = NSAttributedString.Key(
        "dev.sakuracord.selection-field-token-identifier"
    )
}

enum SelectionFieldInputCommand {
    case previous
    case next
    case accept
    case dismiss
}

struct SelectionFieldTokenInput<ID: Hashable & Sendable>: NSViewRepresentable {
    let options: [SelectionFieldOption<ID>]
    let query: String
    let placeholder: String
    let isEditable: Bool
    let usesCards: Bool
    let wantsFocus: Bool
    let onQueryChange: (String) -> Void
    let onRemove: (ID) -> Void
    let onFocusChange: (Bool) -> Void
    let onHeightChange: (CGFloat) -> Void
    let onActivate: () -> Void
    let onCommand: (SelectionFieldInputCommand) -> Bool

    private let font = NSFont.systemFont(ofSize: 14)

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> SelectionFieldTokenScrollView {
        makeEditor(coordinator: context.coordinator)
    }

    func makeEditor(
        coordinator: Coordinator
    ) -> SelectionFieldTokenScrollView {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let textContainer = NSTextContainer()
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)

        let textView = SelectionFieldNSTextView(
            frame: .zero,
            textContainer: textContainer
        )
        textView.delegate = coordinator
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainerInset = NSSize(width: 0, height: 5)
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.autoresizingMask = [.width]
        textView.font = font
        textView.textColor = .labelColor
        textView.applySakuraCordTextSelectionAppearance()
        textView.typingAttributes = Self.textAttributes(font)
        textView.placeholder = placeholder
        textView.onActivate = onActivate
        textView.onCommand = onCommand
        textView.onRemoveToken = { [weak coordinator] identifier in
            coordinator?.remove(identifier: identifier)
        }

        let scrollView = SelectionFieldTokenScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scrollView.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        scrollView.onHeightChange = onHeightChange
        return scrollView
    }

    func updateNSView(
        _ scrollView: SelectionFieldTokenScrollView,
        context: Context
    ) {
        updateEditor(scrollView, coordinator: context.coordinator)
    }

    func updateEditor(
        _ scrollView: SelectionFieldTokenScrollView,
        coordinator: Coordinator
    ) {
        guard let textView = scrollView.documentView
            as? SelectionFieldNSTextView
        else { return }
        coordinator.parent = self
        scrollView.onHeightChange = onHeightChange
        textView.isEditable = isEditable
        textView.placeholder = placeholder
        textView.onActivate = onActivate
        textView.onCommand = onCommand
        textView.onRemoveToken = { [weak coordinator] identifier in
            coordinator?.remove(identifier: identifier)
        }
        coordinator.synchronize(textView)
        coordinator.applyFocus(to: textView)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView scrollView: SelectionFieldTokenScrollView,
        context _: Context
    ) -> CGSize? {
        guard let textView = scrollView.documentView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let width = proposal.width,
              width > 0
        else { return nil }
        textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
        layoutManager.ensureLayout(for: textContainer)
        let lineHeight = layoutManager.defaultLineHeight(for: font)
        let height = ceil(
            max(lineHeight, layoutManager.usedRect(for: textContainer).height)
                + textView.textContainerInset.height * 2
        )
        return CGSize(width: width, height: max(30, height))
    }

    private static func textAttributes(
        _ font: NSFont
    ) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SelectionFieldTokenInput
        private var tokenIDs: [ID: String] = [:]
        private var idsByToken: [String: ID] = [:]
        private var nextTokenID = 0
        private var isSynchronizing = false
        private var appliedFocus = false
        private var imageTasks: [URL: Task<Void, Never>] = [:]

        init(parent: SelectionFieldTokenInput) {
            self.parent = parent
        }

        deinit {
            for task in imageTasks.values { task.cancel() }
        }

        fileprivate func synchronize(_ textView: SelectionFieldNSTextView) {
            let expectedTokens = parent.options.map { tokenID(for: $0.id) }
            let current = content(in: textView.attributedString())
            guard current.tokens != expectedTokens || current.query != parent.query else {
                loadImages(for: parent.options, in: textView)
                return
            }

            isSynchronizing = true
            let value = NSMutableAttributedString()
            for option in parent.options {
                let identifier = tokenID(for: option.id)
                let attachment = SelectionFieldTokenAttachment(
                    identifier: identifier,
                    option: option,
                    font: parent.font,
                    usesCard: parent.usesCards,
                    image: cachedImage(for: option.leading)
                )
                let token = NSMutableAttributedString(attachment: attachment)
                token.addAttributes(
                    [
                        .selectionFieldTokenIdentifier: identifier,
                        .font: parent.font,
                    ],
                    range: NSRange(location: 0, length: token.length)
                )
                value.append(token)
            }
            value.append(NSAttributedString(
                string: parent.query,
                attributes: SelectionFieldTokenInput.textAttributes(parent.font)
            ))
            textView.textStorage?.setAttributedString(value)
            textView.typingAttributes = SelectionFieldTokenInput.textAttributes(
                parent.font
            )
            textView.setSelectedRange(NSRange(location: value.length, length: 0))
            textView.invalidateIntrinsicContentSize()
            textView.enclosingScrollView?.invalidateIntrinsicContentSize()
            isSynchronizing = false
            loadImages(for: parent.options, in: textView)
        }

        func textDidBeginEditing(_ notification: Notification) {
            appliedFocus = true
            parent.onFocusChange(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            appliedFocus = false
            parent.onFocusChange(false)
        }

        func textDidChange(_ notification: Notification) {
            guard !isSynchronizing,
                  let textView = notification.object as? SelectionFieldNSTextView
            else { return }
            let current = content(in: textView.attributedString())
            let retained = Set(current.tokens)
            for option in parent.options {
                let identifier = tokenID(for: option.id)
                if !retained.contains(identifier) {
                    parent.onRemove(option.id)
                }
            }
            if current.query != parent.query {
                parent.onQueryChange(current.query)
            }
            textView.typingAttributes = SelectionFieldTokenInput.textAttributes(
                parent.font
            )
            textView.invalidateIntrinsicContentSize()
            textView.enclosingScrollView?.invalidateIntrinsicContentSize()
        }

        fileprivate func applyFocus(to textView: SelectionFieldNSTextView) {
            guard parent.wantsFocus != appliedFocus else { return }
            if parent.wantsFocus {
                Task { @MainActor [weak textView] in
                    guard let textView,
                          let window = textView.window,
                          parent.wantsFocus
                    else { return }
                    window.makeFirstResponder(textView)
                    appliedFocus = true
                }
            } else if textView.window?.firstResponder === textView {
                textView.window?.makeFirstResponder(nil)
                appliedFocus = false
            } else {
                appliedFocus = false
            }
        }

        func remove(identifier: String) {
            guard let id = idsByToken[identifier] else { return }
            parent.onRemove(id)
        }

        private func tokenID(for id: ID) -> String {
            if let value = tokenIDs[id] { return value }
            nextTokenID += 1
            let value = "selection-token-\(nextTokenID)"
            tokenIDs[id] = value
            idsByToken[value] = id
            return value
        }

        private func content(
            in value: NSAttributedString
        ) -> (tokens: [String], query: String) {
            var tokens: [String] = []
            var query = ""
            value.enumerateAttributes(
                in: NSRange(location: 0, length: value.length)
            ) { attributes, range, _ in
                if let identifier = attributes[.selectionFieldTokenIdentifier]
                    as? String,
                   attributes[.attachment] is NSTextAttachment
                {
                    tokens.append(identifier)
                } else {
                    query += value.attributedSubstring(from: range).string
                }
            }
            return (tokens, query)
        }

        private func cachedImage(
            for leading: SelectionFieldLeading
        ) -> NSImage? {
            let url: URL? = switch leading {
            case .role(_, let iconURL, _): iconURL
            case .remoteImage(let url, _, _): url
            case .none, .systemImage, .text: nil
            }
            guard let url else { return nil }
            return SelectionFieldCachedImage.image(for: url)
        }

        private func loadImages(
            for options: [SelectionFieldOption<ID>],
            in textView: SelectionFieldNSTextView
        ) {
            for option in options {
                let url: URL? = switch option.leading {
                case .role(_, let iconURL, _): iconURL
                case .remoteImage(let url, _, _): url
                case .none, .systemImage, .text: nil
                }
                guard let url,
                      cachedImage(for: option.leading) == nil,
                      imageTasks[url] == nil
                else { continue }
                imageTasks[url] = Task { @MainActor [weak self, weak textView] in
                    guard let self else { return }
                    _ = await MentionAvatarImageStore.shared.image(for: url)
                    imageTasks[url] = nil
                    guard let textView else { return }
                    synchronize(textView)
                }
            }
        }
    }
}

nonisolated private final class SelectionFieldTokenAttachment: NSTextAttachment {
    let identifier: String
    let normalImage: NSImage
    let hoverImage: NSImage
    let removalStartX: CGFloat?

    @MainActor
    init<ID: Hashable & Sendable>(
        identifier: String,
        option: SelectionFieldOption<ID>,
        font: NSFont,
        usesCard: Bool,
        image: NSImage?
    ) {
        self.identifier = identifier
        let rendered = SelectionFieldTokenRenderer.images(
            option: option,
            font: font,
            usesCard: usesCard,
            leadingImage: image
        )
        normalImage = rendered.normal
        hoverImage = rendered.hover
        removalStartX = rendered.removalStartX
        super.init(data: nil, ofType: nil)
        self.image = normalImage
        bounds = CGRect(
            x: 0,
            y: ComposerEmojiAttributedText.attachmentOriginY(
                font: font,
                size: normalImage.size.height
            ),
            width: normalImage.size.width,
            height: normalImage.size.height
        )
        self.image?.accessibilityDescription = option.title
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
enum SelectionFieldTokenRenderer {
    struct Result {
        let normal: NSImage
        let hover: NSImage
        let removalStartX: CGFloat?
    }

    static func images<ID: Hashable & Sendable>(
        option: SelectionFieldOption<ID>,
        font: NSFont,
        usesCard: Bool,
        leadingImage: NSImage?
    ) -> Result {
        let labelFont = NSFont.systemFont(
            ofSize: font.pointSize,
            weight: .semibold
        )
        let labelSize = (option.title as NSString).size(
            withAttributes: [.font: labelFont]
        )
        let height = max(25, ceil(font.pointSize + 9))
        let leadingSize = height - 7
        let hasLeading = option.leading != .none
        let leadingWidth = hasLeading ? leadingSize + 5 : 0
        let closeWidth: CGFloat = usesCard ? 18 : 0
        let contentWidth = ceil(7 + leadingWidth + labelSize.width + closeWidth + 7)
        let width = contentWidth + 4
        let removalStartX = usesCard ? contentWidth - closeWidth - 4 : nil

        func image(hovered: Bool) -> NSImage {
            NSImage(size: NSSize(width: width, height: height), flipped: false) { bounds in
                let card = CGRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: contentWidth,
                    height: bounds.height
                )
                if usesCard {
                    let shape = NSBezierPath(
                        concentricRoundedRect: card,
                        cornerRadius: 6
                    )
                    NSColor.labelColor.withAlphaComponent(
                        hovered ? 0.14 : 0.085
                    ).setFill()
                    shape.fill()
                    NSColor.labelColor.withAlphaComponent(0.10).setStroke()
                    shape.lineWidth = 0.75
                    shape.stroke()
                }

                var contentX: CGFloat = 7
                if hasLeading {
                    let rect = CGRect(
                        x: contentX,
                        y: (height - leadingSize) / 2,
                        width: leadingSize,
                        height: leadingSize
                    )
                    draw(
                        option.leading,
                        image: leadingImage,
                        in: rect
                    )
                    contentX = rect.maxX + 5
                }
                let textY = floor((height - labelSize.height) / 2)
                (option.title as NSString).draw(
                    at: CGPoint(x: contentX, y: textY),
                    withAttributes: [
                        .font: labelFont,
                        .foregroundColor: titleColor(
                            for: option.titleStyle
                        ),
                    ]
                )
                if usesCard {
                    drawSystemImage(
                        "xmark",
                        in: CGRect(
                            x: contentWidth - closeWidth - 1,
                            y: (height - 13) / 2,
                            width: 13,
                            height: 13
                        ),
                        color: .secondaryLabelColor
                    )
                }
                return true
            }
        }

        return Result(
            normal: image(hovered: false),
            hover: image(hovered: true),
            removalStartX: removalStartX
        )
    }

    private static func draw(
        _ leading: SelectionFieldLeading,
        image: NSImage?,
        in rect: CGRect
    ) {
        switch leading {
        case .none:
            return
        case .systemImage(let name):
            drawSystemImage(name, in: rect, color: .secondaryLabelColor)
        case .text(let value):
            let font = NSFont.systemFont(ofSize: rect.height * 0.75)
            let size = (value as NSString).size(withAttributes: [.font: font])
            (value as NSString).draw(
                at: CGPoint(
                    x: rect.midX - size.width / 2,
                    y: rect.midY - size.height / 2
                ),
                withAttributes: [
                    .font: font,
                    .foregroundColor: NSColor.labelColor,
                ]
            )
        case let .role(colorHex, _, unicodeEmoji):
            if let image {
                image.draw(
                    in: rect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: false,
                    hints: [.interpolation: NSImageInterpolation.high]
                )
            } else if let unicodeEmoji, !unicodeEmoji.isEmpty {
                let font = NSFont.systemFont(ofSize: rect.height * 0.75)
                let size = (unicodeEmoji as NSString).size(
                    withAttributes: [.font: font]
                )
                (unicodeEmoji as NSString).draw(
                    at: CGPoint(
                        x: rect.midX - size.width / 2,
                        y: rect.midY - size.height / 2
                    ),
                    withAttributes: [
                        .font: font,
                        .foregroundColor: NSColor.labelColor,
                    ]
                )
            } else {
                RoleColorIndicatorRenderer.draw(
                    colorHex: colorHex,
                    in: rect.insetBy(dx: 3, dy: 3)
                )
            }
        case .remoteImage(_, let fallback, let shape):
            let path = switch shape {
            case .circle:
                NSBezierPath(ovalIn: rect)
            case .roundedRectangle:
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            }
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            if let image {
                image.draw(
                    in: rect,
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1,
                    respectFlipped: false,
                    hints: [.interpolation: NSImageInterpolation.high]
                )
            } else {
                NSColor.sakuraCordAccentColor.withAlphaComponent(0.65).setFill()
                path.fill()
                let value = String(fallback.prefix(1)).uppercased() as NSString
                let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
                let size = value.size(withAttributes: [.font: font])
                value.draw(
                    at: CGPoint(
                        x: rect.midX - size.width / 2,
                        y: rect.midY - size.height / 2
                    ),
                    withAttributes: [
                        .font: font,
                        .foregroundColor: NSColor.white,
                    ]
                )
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private static func titleColor(
        for style: SelectionFieldTitleStyle
    ) -> NSColor {
        switch style {
        case .standard:
            .labelColor
        case .memberColor(let colorHex):
            if SakuraCordAccentColor.usesAccentFallback(
                forRoleColorHex: colorHex
            ) {
                .labelColor
            } else {
                SakuraCordAccentColor.nsColor(
                    forRoleColorHex: colorHex
                )
            }
        case .roleColor(let colorHex):
            SakuraCordAccentColor.nsColor(forRoleColorHex: colorHex)
        }
    }

    private static func drawSystemImage(
        _ name: String,
        in rect: CGRect,
        color: NSColor
    ) {
        let configuration = NSImage.SymbolConfiguration(
            pointSize: rect.height,
            weight: .semibold
        ).applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(configuration)
        else { return }
        image.draw(
            in: rect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: false,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }
}

@MainActor
final class SelectionFieldNSTextView: NSTextView {
    var placeholder = "" {
        didSet { needsDisplay = true }
    }
    var onActivate: () -> Void = {}
    var onCommand: (SelectionFieldInputCommand) -> Bool = { _ in false }
    var onRemoveToken: (String) -> Void = { _ in }
    private var hoveredAttachment: SelectionFieldTokenAttachment?
    private var trackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .activeInKeyWindow,
                .inVisibleRect,
                .mouseMoved,
                .mouseEnteredAndExited,
            ],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let font = font ?? .systemFont(ofSize: 14)
        let rect = CGRect(
            x: textContainerInset.width,
            y: textContainerInset.height,
            width: max(0, bounds.width - textContainerInset.width * 2),
            height: bounds.height
        )
        (placeholder as NSString).draw(
            in: rect,
            withAttributes: [
                .font: font,
                .foregroundColor: NSColor.placeholderTextColor,
            ]
        )
    }

    override func mouseMoved(with event: NSEvent) {
        let next = attachmentHit(at: event)?.attachment
        guard next !== hoveredAttachment else { return }
        hoveredAttachment?.image = hoveredAttachment?.normalImage
        next?.image = next?.hoverImage
        hoveredAttachment = next
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoveredAttachment?.image = hoveredAttachment?.normalImage
        hoveredAttachment = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if !isEditable {
            onActivate()
            return
        }
        if let hit = attachmentHit(at: event),
           let removalStartX = hit.attachment.removalStartX,
           hit.localX >= removalStartX
        {
            onRemoveToken(hit.attachment.identifier)
            return
        }
        onActivate()
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let command: SelectionFieldInputCommand? = switch event.keyCode {
        case 126: .previous
        case 125: .next
        case 36, 76: .accept
        case 53: .dismiss
        default: nil
        }
        if let command, onCommand(command) { return }
        super.keyDown(with: event)
    }

    private func attachmentHit(
        at event: NSEvent
    ) -> (attachment: SelectionFieldTokenAttachment, localX: CGFloat)? {
        guard let layoutManager, let textContainer else { return nil }
        var point = convert(event.locationInWindow, from: nil)
        point.x -= textContainerOrigin.x
        point.y -= textContainerOrigin.y
        guard point.x >= 0, point.y >= 0 else { return nil }
        let glyph = layoutManager.glyphIndex(
            for: point,
            in: textContainer,
            fractionOfDistanceThroughGlyph: nil
        )
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyph, length: 1),
            in: textContainer
        )
        guard glyphRect.contains(point) else { return nil }
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        guard character < attributedString().length,
              let attachment = attributedString().attribute(
                  .attachment,
                  at: character,
                  effectiveRange: nil
              ) as? SelectionFieldTokenAttachment
        else { return nil }
        return (attachment, point.x - glyphRect.minX)
    }
}

final class SelectionFieldTokenScrollView: NSScrollView {
    var onHeightChange: (CGFloat) -> Void = { _ in }
    private var reportedHeight: CGFloat = 0
    private(set) var measuredHeight: CGFloat = 30

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        tile()
        synchronizeDocumentWidth()
    }

    override func layout() {
        super.layout()
        synchronizeDocumentWidth()
    }

    override func scrollWheel(with event: NSEvent) {
        if !forwardSelectionFieldScrollWheel(event, from: self) {
            super.scrollWheel(with: event)
        }
    }

    private func synchronizeDocumentWidth() {
        guard let textView = documentView as? NSTextView else { return }
        let width = contentSize.width
        guard width > 0 else { return }
        if abs(textView.frame.width - width) > 0.5 {
            textView.setFrameSize(
                NSSize(width: width, height: textView.frame.height)
            )
        }
        textView.textContainer?.containerSize = NSSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        )
        if let layoutManager = textView.layoutManager,
           let textContainer = textView.textContainer
        {
            layoutManager.ensureLayout(for: textContainer)
            let lineHeight = layoutManager.defaultLineHeight(
                for: textView.font ?? .systemFont(ofSize: 14)
            )
            let height = max(
                30,
                ceil(
                    max(
                        lineHeight,
                        layoutManager.usedRect(for: textContainer).height
                    ) + textView.textContainerInset.height * 2
                )
            )
            measuredHeight = height
            let documentHeight = max(contentSize.height, height)
            if abs(textView.frame.height - documentHeight) > 0.5 {
                textView.setFrameSize(
                    NSSize(width: width, height: documentHeight)
                )
            }
            if abs(height - reportedHeight) > 0.5 {
                reportedHeight = height
                Task { @MainActor [onHeightChange] in
                    onHeightChange(height)
                }
            }
        }
        if contentView.bounds.origin.x != 0 {
            contentView.scroll(to: NSPoint(x: 0, y: contentView.bounds.origin.y))
            reflectScrolledClipView(contentView)
        }
    }
}
