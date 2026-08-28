import AppKit

@MainActor
enum SelectionFieldCachedImage {
    private static let decodedDimensions = [96, 64]

    static func image(for url: URL) -> NSImage? {
        if url.isFileURL { return NSImage(contentsOf: url) }
        if let image = MentionAvatarImageStore.shared.cachedImage(for: url) {
            return image
        }
        for maximumPixelDimension in decodedDimensions {
            if let image = SharedDecodedImageLoader.shared.cachedImage(
                for: url,
                maximumPixelDimension: maximumPixelDimension
            ) {
                return NSImage(
                    cgImage: image,
                    size: NSSize(
                        width: CGFloat(image.width),
                        height: CGFloat(image.height)
                    )
                )
            }
        }
        return nil
    }

    static func cgImage(for url: URL) -> CGImage? {
        for maximumPixelDimension in decodedDimensions {
            if let image = SharedDecodedImageLoader.shared.cachedImage(
                for: url,
                maximumPixelDimension: maximumPixelDimension
            ) {
                return image
            }
        }
        guard let image = image(for: url) else { return nil }
        var proposedRect = CGRect(
            origin: .zero,
            size: image.size
        )
        return image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        )
    }
}

@MainActor
@discardableResult
func forwardSelectionFieldScrollWheel(
    _ event: NSEvent,
    from view: NSView
) -> Bool {
    var ancestor = view.superview
    while let current = ancestor {
        if let scrollView = current as? NSScrollView {
            scrollView.scrollWheel(with: event)
            return true
        }
        ancestor = current.superview
    }
    return false
}

@MainActor
enum SelectionFieldLayoutMetrics {
    static let font = NSFont.systemFont(ofSize: 14)
    static let minimumHeight: CGFloat = 42
    static let tokenHeight: CGFloat = 25
    static let verticalInset: CGFloat = 5
    static let leadingInset: CGFloat = 11
    static let trailingAccessoryInset: CGFloat = 38
    static let expandedAccessoryWidth: CGFloat = 49
    static let expandedAccessoryWidthWithClear: CGFloat = 76

    static func preferredHeight<ID: Hashable & Sendable>(
        options: [SelectionFieldOption<ID>],
        width: CGFloat,
        usesCards: Bool
    ) -> CGFloat {
        guard !options.isEmpty else { return minimumHeight }
        let availableWidth = max(
            1,
            width - leadingInset - trailingAccessoryInset
        )
        var lineCount = 1
        var lineWidth: CGFloat = 0
        for option in options {
            let tokenWidth = SelectionFieldTokenRenderer.images(
                option: option,
                font: font,
                usesCard: usesCards,
                leadingImage: nil
            ).normal.size.width
            if lineWidth > 0, lineWidth + tokenWidth > availableWidth {
                lineCount += 1
                lineWidth = tokenWidth
            } else {
                lineWidth += tokenWidth
            }
        }
        return max(
            minimumHeight,
            verticalInset * 2 + CGFloat(lineCount) * tokenHeight
        )
    }
}

@MainActor
enum SelectionFieldChromeRenderer {
    static func chevronRect(in frame: CGRect) -> CGRect {
        CGRect(
            x: frame.maxX - 31,
            y: frame.midY - 10,
            width: 20,
            height: 20
        )
    }

    static func drawText(
        _ value: String,
        in frame: CGRect,
        color: NSColor,
        opacity: CGFloat = 1
    ) {
        guard !value.isEmpty else { return }
        let font = SelectionFieldLayoutMetrics.font
        let lineHeight = ceil(font.boundingRectForFont.height)
        (value as NSString).draw(
            in: CGRect(
                x: frame.minX + SelectionFieldLayoutMetrics.leadingInset,
                y: floor(frame.midY - lineHeight / 2),
                width: max(1, frame.width - 65),
                height: lineHeight + 2
            ),
            withAttributes: [
                .font: font,
                .foregroundColor: color.withAlphaComponent(
                    color.alphaComponent * opacity
                ),
            ]
        )
    }

    static func drawChevron(
        isExpanded: Bool,
        in frame: CGRect,
        opacity: CGFloat = 1
    ) {
        drawSystemImage(
            isExpanded ? "chevron.up" : "chevron.down",
            in: chevronRect(in: frame),
            pointSize: 12,
            weight: .semibold,
            opacity: opacity
        )
    }

    static func drawSystemImage(
        _ name: String,
        in rect: CGRect,
        pointSize: CGFloat,
        weight: NSFont.Weight,
        opacity: CGFloat = 1
    ) {
        let color = NSColor.secondaryLabelColor.withAlphaComponent(opacity)
        let configuration = NSImage.SymbolConfiguration(
            pointSize: pointSize,
            weight: weight
        ).applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(configuration)
        else { return }
        let destination = NativeTimelineSymbolGeometry.opticallyFitted(
            sourceSize: image.size,
            alignmentRect: image.alignmentRect,
            in: rect
        )
        image.draw(
            in: destination,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }
}

@MainActor
struct SelectionFieldControlConfiguration<ID: Hashable & Sendable> {
    let options: [SelectionFieldOption<ID>]
    let query: String
    let placeholder: String
    let isEditable: Bool
    let usesCards: Bool
    let isExpanded: Bool
    let wantsFocus: Bool
    var isEnabled = true
    let onQueryChange: (String) -> Void
    let onRemove: (ID) -> Void
    let onFocusChange: (Bool) -> Void
    let onActivate: () -> Void
    let onCommand: (SelectionFieldInputCommand) -> Bool
    let onToggle: () -> Void
}

@MainActor
class SelectionFieldControl<ID: Hashable & Sendable>: NSGlassEffectView {
    private let fieldContent = SelectionFieldControlContentView<ID>()

    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        style = .regular
        cornerRadius = 11
        effectIsInteractive = false
        contentView = fieldContent
        fieldContent.heightDidChange = { [weak self] in
            self?.invalidateIntrinsicContentSize()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: fieldContent.preferredHeight(forWidth: bounds.width)
        )
    }

    override func scrollWheel(with event: NSEvent) {
        if !forwardSelectionFieldScrollWheel(event, from: self) {
            super.scrollWheel(with: event)
        }
    }

    func preferredHeight(forWidth width: CGFloat) -> CGFloat {
        fieldContent.preferredHeight(forWidth: width)
    }

    func update(_ configuration: SelectionFieldControlConfiguration<ID>) {
        effectIsInteractive = false
        alphaValue = configuration.isEnabled ? 1 : 0.65
        fieldContent.update(configuration)
    }
}

@MainActor
private final class SelectionFieldControlContentView<
    ID: Hashable & Sendable
>: NSView {
    private struct Token {
        let id: ID
        let rect: CGRect
        let normalImage: NSImage
        let hoverImage: NSImage
        let removalStartX: CGFloat?
    }

    private struct CachedTokenImages {
        let option: SelectionFieldOption<ID>
        let usesCards: Bool
        let hasLeadingImage: Bool
        let images: SelectionFieldTokenRenderer.Result
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var heightDidChange: () -> Void = {}

    private var options: [SelectionFieldOption<ID>] = []
    private var query = ""
    private var placeholder = ""
    private var isEditable = false
    private var usesCards = true
    private var isExpanded = false
    private var wantsFocus = false
    private var isEnabled = true
    private var onQueryChange: (String) -> Void = { _ in }
    private var onRemove: (ID) -> Void = { _ in }
    private var onFocusChange: (Bool) -> Void = { _ in }
    private var onActivate: () -> Void = {}
    private var onCommand: (SelectionFieldInputCommand) -> Bool = { _ in false }
    private var onToggle: () -> Void = {}
    private var editor: SelectionFieldTokenScrollView?
    private var editorCoordinator: SelectionFieldTokenInput<ID>.Coordinator?
    private var hoveredTokenID: ID?
    private var trackingArea: NSTrackingArea?
    private var imageTasks: [URL: Task<Void, Never>] = [:]
    private var tokenImageCache: [ID: CachedTokenImages] = [:]

    isolated deinit {
        for task in imageTasks.values { task.cancel() }
    }

    func update(_ configuration: SelectionFieldControlConfiguration<ID>) {
        let previousHeight = preferredHeight(forWidth: bounds.width)
        let tokenContentChanged = options != configuration.options
            || usesCards != configuration.usesCards
        let appearanceChanged = tokenContentChanged
            || query != configuration.query
            || placeholder != configuration.placeholder
            || isExpanded != configuration.isExpanded

        if tokenContentChanged {
            tokenImageCache.removeAll(keepingCapacity: true)
        }

        options = configuration.options
        query = configuration.query
        placeholder = configuration.placeholder
        isEditable = configuration.isEditable
        usesCards = configuration.usesCards
        isExpanded = configuration.isExpanded
        wantsFocus = configuration.wantsFocus
        isEnabled = configuration.isEnabled
        onQueryChange = configuration.onQueryChange
        onRemove = configuration.onRemove
        onFocusChange = configuration.onFocusChange
        onActivate = configuration.onActivate
        onCommand = configuration.onCommand
        onToggle = configuration.onToggle

        if configuration.isExpanded {
            updateEditor()
        } else {
            removeEditor()
            loadImages()
        }
        if appearanceChanged { needsDisplay = true }
        needsLayout = true
        if abs(previousHeight - preferredHeight(forWidth: bounds.width)) > 0.5 {
            heightDidChange()
        }
    }

    func preferredHeight(forWidth width: CGFloat) -> CGFloat {
        if isExpanded, let editor {
            return max(
                SelectionFieldLayoutMetrics.minimumHeight,
                editor.measuredHeight
            )
        }
        return SelectionFieldLayoutMetrics.preferredHeight(
            options: options,
            width: width,
            usesCards: usesCards
        )
    }

    override func layout() {
        super.layout()
        guard let editor else { return }
        let accessoryWidth = query.isEmpty
            ? SelectionFieldLayoutMetrics.expandedAccessoryWidth
            : SelectionFieldLayoutMetrics.expandedAccessoryWidthWithClear
        let editorHeight = max(30, editor.measuredHeight)
        editor.frame = CGRect(
            x: SelectionFieldLayoutMetrics.leadingInset,
            y: floor((bounds.height - editorHeight) / 2),
            width: max(
                1,
                bounds.width - accessoryWidth
                    - SelectionFieldLayoutMetrics.leadingInset
            ),
            height: editorHeight
        )
    }

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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        tokenImageCache.removeAll(keepingCapacity: true)
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isExpanded else { return }
        let point = convert(event.locationInWindow, from: nil)
        let next = tokens().first(where: { $0.rect.contains(point) })?.id
        guard next != hoveredTokenID else { return }
        hoveredTokenID = next
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard hoveredTokenID != nil else { return }
        hoveredTokenID = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        if chevronRect.contains(point) {
            onToggle()
            return
        }
        if !query.isEmpty, clearRect.contains(point) {
            onQueryChange("")
            return
        }
        if !isExpanded,
           let token = tokens().first(where: { $0.rect.contains(point) }),
           let removalStartX = token.removalStartX,
           point.x - token.rect.minX >= removalStartX
        {
            onRemove(token.id)
            return
        }
        onActivate()
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

    override func scrollWheel(with event: NSEvent) {
        if !forwardSelectionFieldScrollWheel(event, from: self) {
            super.scrollWheel(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawBorder()
        if isExpanded {
            if options.isEmpty, query.isEmpty {
                SelectionFieldChromeRenderer.drawText(
                    placeholder,
                    in: bounds,
                    color: .placeholderTextColor
                )
            }
        } else {
            drawCollapsedContent()
        }
        if !query.isEmpty { drawClearButton() }
        drawChevron()
    }

    private func updateEditor() {
        let input = SelectionFieldTokenInput(
            options: options,
            query: query,
            placeholder: "",
            isEditable: isEditable,
            usesCards: usesCards,
            wantsFocus: wantsFocus,
            onQueryChange: onQueryChange,
            onRemove: onRemove,
            onFocusChange: onFocusChange,
            onHeightChange: { [weak self] _ in
                guard let self else { return }
                needsLayout = true
                heightDidChange()
            },
            onActivate: onActivate,
            onCommand: onCommand
        )
        if let editor, let editorCoordinator {
            input.updateEditor(editor, coordinator: editorCoordinator)
            return
        }
        let coordinator = input.makeCoordinator()
        let editor = input.makeEditor(coordinator: coordinator)
        addSubview(editor)
        self.editor = editor
        editorCoordinator = coordinator
        input.updateEditor(editor, coordinator: coordinator)
    }

    private func removeEditor() {
        guard let editor else { return }
        if editor.window?.firstResponder === editor.documentView {
            editor.window?.makeFirstResponder(nil)
        }
        editor.removeFromSuperview()
        self.editor = nil
        editorCoordinator = nil
    }

    private func drawBorder() {
        NSColor.labelColor.withAlphaComponent(0.24).setStroke()
        let border = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 10.5,
            yRadius: 10.5
        )
        border.lineWidth = 1
        border.stroke()
    }

    private func drawCollapsedContent() {
        let tokens = tokens()
        for token in tokens {
            let image = token.id == hoveredTokenID
                ? token.hoverImage
                : token.normalImage
            image.draw(
                in: token.rect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
        }
        guard tokens.isEmpty else { return }
        let text = query.isEmpty ? placeholder : query
        let color: NSColor = query.isEmpty
            ? .placeholderTextColor
            : .labelColor
        SelectionFieldChromeRenderer.drawText(
            text,
            in: bounds,
            color: color
        )
    }

    private func tokens() -> [Token] {
        guard !options.isEmpty else { return [] }
        let maximumX = bounds.maxX
            - SelectionFieldLayoutMetrics.trailingAccessoryInset
        var rendered: [(ID, SelectionFieldTokenRenderer.Result)] = []
        rendered.reserveCapacity(options.count)
        for option in options {
            rendered.append((option.id, renderedToken(for: option)))
        }
        var lineCount = 1
        var lineWidth: CGFloat = 0
        for (_, images) in rendered {
            let width = images.normal.size.width
            if lineWidth > 0, SelectionFieldLayoutMetrics.leadingInset
                + lineWidth + width > maximumX
            {
                lineCount += 1
                lineWidth = width
            } else {
                lineWidth += width
            }
        }
        let contentHeight = CGFloat(lineCount)
            * SelectionFieldLayoutMetrics.tokenHeight
        let originY = max(
            SelectionFieldLayoutMetrics.verticalInset,
            floor((bounds.height - contentHeight) / 2)
        )
        var origin = CGPoint(
            x: SelectionFieldLayoutMetrics.leadingInset,
            y: originY
        )
        var result: [Token] = []
        result.reserveCapacity(rendered.count)
        for (id, images) in rendered {
            let size = images.normal.size
            if origin.x > SelectionFieldLayoutMetrics.leadingInset,
               origin.x + size.width > maximumX
            {
                origin.x = SelectionFieldLayoutMetrics.leadingInset
                origin.y += SelectionFieldLayoutMetrics.tokenHeight
            }
            result.append(Token(
                id: id,
                rect: CGRect(origin: origin, size: size),
                normalImage: images.normal,
                hoverImage: images.hover,
                removalStartX: images.removalStartX
            ))
            origin.x += size.width
        }
        return result
    }

    private func renderedToken(
        for option: SelectionFieldOption<ID>
    ) -> SelectionFieldTokenRenderer.Result {
        let leadingImage = cachedImage(for: option.leading)
        let hasLeadingImage = leadingImage != nil
        if let cached = tokenImageCache[option.id],
           cached.option == option,
           cached.usesCards == usesCards,
           cached.hasLeadingImage == hasLeadingImage
        {
            return cached.images
        }
        let images = SelectionFieldTokenRenderer.images(
            option: option,
            font: SelectionFieldLayoutMetrics.font,
            usesCard: usesCards,
            leadingImage: leadingImage
        )
        tokenImageCache[option.id] = CachedTokenImages(
            option: option,
            usesCards: usesCards,
            hasLeadingImage: hasLeadingImage,
            images: images
        )
        return images
    }

    private var chevronRect: CGRect {
        SelectionFieldChromeRenderer.chevronRect(in: bounds)
    }

    private var clearRect: CGRect {
        CGRect(
            x: bounds.maxX - 58,
            y: bounds.midY - 10,
            width: 20,
            height: 20
        )
    }

    private func drawChevron() {
        SelectionFieldChromeRenderer.drawChevron(
            isExpanded: isExpanded,
            in: bounds
        )
    }

    private func drawClearButton() {
        SelectionFieldChromeRenderer.drawSystemImage(
            "xmark.circle.fill",
            in: clearRect,
            pointSize: 13,
            weight: .regular
        )
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

    private func loadImages() {
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
            imageTasks[url] = Task { @MainActor [weak self] in
                _ = await MentionAvatarImageStore.shared.image(for: url)
                self?.imageTasks[url] = nil
                self?.tokenImageCache.removeAll(keepingCapacity: true)
                self?.needsDisplay = true
            }
        }
    }
}
