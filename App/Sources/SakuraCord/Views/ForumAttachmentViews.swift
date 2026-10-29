import AppKit
import SakuraCordModels
import SwiftUI
import UniformTypeIdentifiers

private enum ForumAttachmentTrayCoordinateSpace {
    static let name = "forum-composer-attachment-tray"
}

private struct ForumAttachmentFramePreferenceKey: PreferenceKey {
    static var defaultValue: [URL: CGRect] = [:]

    static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

struct ForumComposerAttachmentControl: View {
    @AppStorage(PrivacySafetySettingsStore.anonymiseFileNamesKey, store: PRBuildProfile.defaults) private var anonymisesFileNames = false
    @Binding var attachments: [ForumPostAttachment]
    let addAttachments: () -> Void
    @State private var editingTarget: ForumAttachmentEditorTarget?
    @State private var isExpanded = false
    @State private var scrollTarget: URL?
    @State private var hoveredAttachmentURL: URL?
    @State private var attachmentFrames: [URL: CGRect] = [:]
    @State private var attachmentThumbnails: [URL: NSImage] = [:]
    @State private var isHoveringAttachmentActions = false
    @State private var hoverDismissalTask: Task<Void, Never>?

    private let tileSize: CGFloat = InterfaceScale.metric(78)
    private let traySpacing: CGFloat = InterfaceScale.metric(8)
    private let trayInset: CGFloat = InterfaceScale.metric(8)
    private let maximumExpandedWidth: CGFloat = InterfaceScale.metric(440)
    private var hoverPillWidth: CGFloat { anonymisesFileNames ? 89 : 68 }

    var body: some View {
        Color.clear
            .frame(width: tileSize, height: tileSize)
            .overlay(alignment: .topTrailing) {
                if attachments.isEmpty {
                    addAttachmentButton
                } else {
                    attachmentTray
                }
            }
            .overlay(alignment: .topTrailing) {
                if attachments.count > 1, !isExpanded {
                    attachmentCountBadge
                        .offset(x: InterfaceScale.metric(5), y: -5)
                        .allowsHitTesting(false)
                }
            }
            .zIndex(20)
            .sheet(item: $editingTarget) { target in
                if let attachment = attachments.first(where: { $0.url == target.id }) {
                    ForumAttachmentEditor(
                        attachment: attachment,
                        cancel: { editingTarget = nil },
                        save: { updated in
                            guard let index = attachments.firstIndex(where: { $0.url == target.id }) else {
                                editingTarget = nil
                                return
                            }
                            attachments[index] = updated
                            editingTarget = nil
                        }
                    )
                }
            }
            .onChange(of: anonymisesFileNames) { _, enabled in
                attachments = attachments.map {
                    var attachment = $0
                    attachment.setFilenameAnonymised(enabled)
                    return attachment
                }
            }
            .onDisappear {
                hoverDismissalTask?.cancel()
            }
    }

    private var itemCount: Int {
        attachments.count
    }

    private var attachmentContentWidth: CGFloat {
        CGFloat(itemCount) * tileSize + CGFloat(max(0, itemCount - 1)) * traySpacing
    }

    private var pinnedAddButtonWidth: CGFloat {
        attachments.count < 10 ? tileSize + traySpacing : 0
    }

    private var expandedAttachmentViewportWidth: CGFloat {
        min(
            attachmentContentWidth,
            maximumExpandedWidth - (trayInset * 2) - pinnedAddButtonWidth
        )
    }

    private var expandedWidth: CGFloat {
        (trayInset * 2) + expandedAttachmentViewportWidth + pinnedAddButtonWidth
    }

    private var currentWidth: CGFloat {
        isExpanded ? expandedWidth : tileSize
    }

    private var currentHeight: CGFloat {
        isExpanded ? tileSize + (trayInset * 2) : tileSize
    }

    private var attachmentCountBadge: some View {
        Text("\(attachments.count)")
            .font(.interface(.caption).weight(.bold))
            .foregroundStyle(.white)
            .frame(width: InterfaceScale.metric(22), height: InterfaceScale.metric(22))
            .background {
                Circle().fill(SakuraCordAccentColor.color)
            }
            .overlay {
                Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5)
            }
            .accessibilityLabel("\(attachments.count) attachments")
    }

    private var attachmentTray: some View {
        HStack(spacing: traySpacing) {
            attachmentScrollView

            if isExpanded, attachments.count < 10 {
                addAttachmentButton
                    .onModalHover { hovering in
                        if hovering {
                            clearHoveredAttachment()
                        }
                    }
            }
        }
        .padding(isExpanded ? trayInset : 0)
        .frame(width: currentWidth, height: currentHeight, alignment: .trailing)
        .background {
            if isExpanded {
                ConcentricRectangle(cornerRadius: InterfaceScale.metric(18), style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        ConcentricRectangle(cornerRadius: InterfaceScale.metric(18), style: .continuous)
                            .stroke(.separator, lineWidth: 1)
                    }
            }
        }
        .coordinateSpace(name: ForumAttachmentTrayCoordinateSpace.name)
        .onPreferenceChange(ForumAttachmentFramePreferenceKey.self) {
            attachmentFrames = $0
        }
        .overlay(alignment: .topLeading) {
            hoveredAttachmentActions
        }
        .contentShape(ConcentricRectangle(cornerRadius: InterfaceScale.metric(18), style: .continuous))
        .onModalHover { hovering in
            isExpanded = hovering
            if !hovering {
                clearHoveredAttachment()
                scrollTarget = attachments.first?.url
            }
        }
        .offset(
            x: isExpanded ? trayInset : 0,
            y: isExpanded ? -trayInset : 0
        )
    }

    private var attachmentScrollView: some View {
        ScrollView(.horizontal) {
            HStack(spacing: traySpacing) {
                ForEach(attachments, id: \.url) { attachment in
                    attachmentTile(attachment)
                        .id(attachment.url)
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: ForumAttachmentFramePreferenceKey.self,
                                    value: [
                                        attachment.url: proxy.frame(
                                            in: .named(ForumAttachmentTrayCoordinateSpace.name)
                                        )
                                    ]
                                )
                            }
                        }
                }
            }
        }
        .scrollPosition(id: $scrollTarget, anchor: .leading)
        .scrollIndicators(.hidden)
        .scrollDisabled(!isExpanded || attachmentContentWidth <= expandedAttachmentViewportWidth)
        .frame(
            width: isExpanded ? expandedAttachmentViewportWidth : tileSize,
            height: tileSize
        )
        .clipShape(ConcentricRectangle(cornerRadius: InterfaceScale.metric(14), style: .continuous))
        .onChange(of: isExpanded) { _, expanded in
            if !expanded {
                scrollTarget = attachments.first?.url
            }
        }
    }

    @ViewBuilder
    private var hoveredAttachmentActions: some View {
        if isExpanded,
           let url = hoveredAttachmentURL,
           let attachment = attachments.first(where: { $0.url == url }),
           let frame = attachmentFrames[url]
        {
            attachmentActions(for: attachment)
                .frame(width: hoverPillWidth)
                .offset(
                    x: frame.maxX - hoverPillWidth + 8,
                    y: frame.minY - 8
                )
                .onModalHover { hovering in
                    isHoveringAttachmentActions = hovering
                    if hovering {
                        hoverDismissalTask?.cancel()
                    } else {
                        scheduleHoverDismissal(for: url)
                    }
                }
                .zIndex(10)
        }
    }

    private func attachmentActions(for attachment: ForumPostAttachment) -> some View {
        HoverActionPill(glass: .regular.interactive(), spacing: 1, padding: 3) {
            HoverActionButton(
                systemImage: attachment.isSpoiler ? "eye.slash" : "eye",
                help: attachment.isSpoiler ? "Remove spoiler" : "Mark as spoiler",
                isSelected: attachment.isSpoiler,
                diameter: InterfaceScale.metric(20),
                iconFont: .interface(.caption2).weight(.semibold),
                action: { toggleSpoiler(for: attachment.url) }
            )
            if anonymisesFileNames {
                HoverActionButton(
                    systemImage: "shuffle",
                    help: attachment.isFilenameAnonymised ? "Restore file name" : "Randomise file name",
                    isSelected: attachment.isFilenameAnonymised,
                    diameter: InterfaceScale.metric(20),
                    iconFont: .interface(.caption2).weight(.semibold)
                ) {
                    toggleFilenamePrivacy(for: attachment.url)
                }
            }
            HoverActionButton(
                systemImage: "pencil",
                help: "Edit attachment",
                diameter: InterfaceScale.metric(20),
                iconFont: .interface(.caption2).weight(.semibold),
                action: { editingTarget = ForumAttachmentEditorTarget(id: attachment.url) }
            )
            HoverActionButton(
                systemImage: "trash",
                help: "Delete attachment",
                role: .destructive,
                diameter: InterfaceScale.metric(20),
                iconFont: .interface(.caption2).weight(.semibold),
                action: { deleteAttachment(attachment.url) }
            )
        }
    }

    private var addAttachmentButton: some View {
        Button(action: addAttachments) {
            Image(systemName: "photo.badge.plus")
                .symbolVariant(.none)
                .font(.interfaceSystem(size: 22, weight: .medium))
                .frame(width: tileSize, height: tileSize)
                .contentShape(ConcentricRectangle(cornerRadius: InterfaceScale.metric(14), style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.interactive(),
            in: ConcentricRectangle(cornerRadius: InterfaceScale.metric(14), style: .continuous)
        )
        .overlay {
            ConcentricRectangle(cornerRadius: InterfaceScale.metric(14), style: .continuous)
                .stroke(.separator, lineWidth: 1)
        }
        .help("Add attachments")
        .accessibilityLabel("Add Attachments")
    }

    private func attachmentTile(_ attachment: ForumPostAttachment) -> some View {
        ForumComposerAttachmentTile(
            attachment: attachment,
            thumbnail: attachmentThumbnails[attachment.url],
            size: tileSize,
            toggleSpoiler: { toggleSpoiler(for: attachment.url) },
            edit: { editingTarget = ForumAttachmentEditorTarget(id: attachment.url) },
            delete: { deleteAttachment(attachment.url) },
            thumbnailLoaded: { image in
                if attachmentThumbnails[attachment.url] == nil {
                    attachmentThumbnails[attachment.url] = image
                }
            },
            hoverChanged: { hovering in
                if hovering {
                    hoverDismissalTask?.cancel()
                    hoveredAttachmentURL = attachment.url
                } else {
                    scheduleHoverDismissal(for: attachment.url)
                }
            }
        )
    }

    private func toggleFilenamePrivacy(for url: URL) {
        guard let index = attachments.firstIndex(where: { $0.url == url }) else { return }
        attachments[index].setFilenameAnonymised(!attachments[index].isFilenameAnonymised)
    }

    private func toggleSpoiler(for url: URL) {
        guard let index = attachments.firstIndex(where: { $0.url == url }) else { return }
        attachments[index].isSpoiler.toggle()
    }

    private func deleteAttachment(_ url: URL) {
        clearHoveredAttachment()
        attachments.removeAll { $0.url == url }
        attachmentThumbnails.removeValue(forKey: url)
        scrollTarget = attachments.first?.url
        if attachments.isEmpty {
            isExpanded = false
        }
    }

    private func scheduleHoverDismissal(for url: URL) {
        hoverDismissalTask?.cancel()
        hoverDismissalTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(75))
            guard !Task.isCancelled,
                  !isHoveringAttachmentActions,
                  hoveredAttachmentURL == url
            else { return }
            hoveredAttachmentURL = nil
        }
    }

    private func clearHoveredAttachment() {
        hoverDismissalTask?.cancel()
        hoverDismissalTask = nil
        isHoveringAttachmentActions = false
        hoveredAttachmentURL = nil
    }
}

private struct ForumComposerAttachmentTile: View {
    let attachment: ForumPostAttachment
    let thumbnail: NSImage?
    var size: CGFloat = 108
    let toggleSpoiler: () -> Void
    let edit: () -> Void
    let delete: () -> Void
    let thumbnailLoaded: (NSImage) -> Void
    let hoverChanged: (Bool) -> Void

    var body: some View {
        ZStack {
            LocalAttachmentThumbnail(
                url: attachment.url,
                cachedImage: thumbnail,
                onImageLoaded: thumbnailLoaded
            )
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }

            if attachment.isSpoiler {
                Rectangle()
                    .fill(.black.opacity(0.5))
                VStack(spacing: InterfaceScale.metric(4)) {
                    Image(systemName: "eye.slash")
                    Text("SPOILER")
                        .font(.interface(.caption2).weight(.bold))
                }
                .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .background(.quaternary)
        .clipShape(ConcentricRectangle(cornerRadius: InterfaceScale.metric(14), style: .continuous))
        .overlay {
            ConcentricRectangle(cornerRadius: InterfaceScale.metric(14), style: .continuous)
                .stroke(.separator, lineWidth: 1)
        }
        .contentShape(ConcentricRectangle(cornerRadius: InterfaceScale.metric(14), style: .continuous))
        .onModalHover(perform: hoverChanged)
        .help(attachment.filename)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(attachment.filename)
        .accessibilityAction(
            named: attachment.isSpoiler ? "Remove spoiler" : "Mark as spoiler",
            toggleSpoiler
        )
        .accessibilityAction(named: "Edit attachment", edit)
        .accessibilityAction(named: "Delete attachment", delete)
    }
}

struct ForumAttachmentEditorTarget: Identifiable {
    let id: URL
}

struct ForumAttachmentEditor: View {
    let attachment: ForumPostAttachment
    let cancel: () -> Void
    let save: (ForumPostAttachment) -> Void
    @State private var filename: String
    @State private var description: String
    @State private var isSpoiler: Bool

    init(
        attachment: ForumPostAttachment,
        cancel: @escaping () -> Void,
        save: @escaping (ForumPostAttachment) -> Void
    ) {
        self.attachment = attachment
        self.cancel = cancel
        self.save = save
        _filename = State(initialValue: attachment.filename)
        _description = State(initialValue: attachment.description)
        _isSpoiler = State(initialValue: attachment.isSpoiler)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(20)) {
            HStack {
                Text("Modify Attachment")
                    .font(.interface(.title2).bold())
                Spacer()
                Button("Close", systemImage: "xmark", action: cancel)
                    .labelStyle(.iconOnly)
                    .font(.interface(.title3))
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
            }

            HStack(alignment: .top, spacing: InterfaceScale.metric(24)) {
                LocalAttachmentThumbnail(url: attachment.url, maximumPixelDimension: 480)
                    .frame(width: InterfaceScale.metric(220), height: InterfaceScale.metric(220))
                    .background(.quaternary)
                    .clipShape(ConcentricRectangle(cornerRadius: InterfaceScale.metric(14), style: .continuous))

                VStack(alignment: .leading, spacing: InterfaceScale.metric(18)) {
                    VStack(alignment: .leading, spacing: InterfaceScale.metric(7)) {
                        Text("Filename").font(.interface(.headline))
                        TextField("Filename", text: $filename)
                            .tint(SakuraCordAccentColor.color)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: InterfaceScale.metric(7)) {
                        HStack {
                            Text("Description (Alt Text)").font(.interface(.headline))
                            Spacer()
                            Text("\(description.count)/1024")
                                .font(.interface(.caption))
                                .foregroundStyle(.secondary)
                        }
                        TextEditor(text: $description)
                            .tint(SakuraCordAccentColor.color)
                            .font(.interface(.body))
                            .scrollContentBackground(.hidden)
                            .padding(InterfaceScale.metric(7))
                            .background(.quaternary, in: ConcentricRectangle(cornerRadius: InterfaceScale.metric(8)))
                            .overlay {
                                ConcentricRectangle(cornerRadius: InterfaceScale.metric(8))
                                    .stroke(.separator, lineWidth: 1)
                            }
                            .frame(minHeight: InterfaceScale.metric(116))
                            .onChange(of: description) { _, value in
                                if value.count > 1_024 {
                                    description = String(value.prefix(1_024))
                                }
                            }
                    }

                    Toggle("Mark as spoiler", isOn: $isSpoiler)
                        .tint(SakuraCordAccentColor.color)
                        .toggleStyle(.checkbox)
                }
                .frame(maxWidth: .infinity)
            }

            Spacer(minLength: 0)

            HStack(spacing: InterfaceScale.metric(10)) {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    var updated = attachment
                    let name = filename.trimmingCharacters(in: .whitespacesAndNewlines)
                    if name != attachment.filename { updated.rename(name) }
                    updated.description = description
                    updated.isSpoiler = isSpoiler
                    save(updated)
                }
                .buttonStyle(.borderedProminent)
                .tint(SakuraCordAccentColor.color)
                .keyboardShortcut(.defaultAction)
                .disabled(filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.large)
        }
        .padding(InterfaceScale.metric(24))
        .frame(
            minWidth: InterfaceScale.metric(560),
            idealWidth: InterfaceScale.metric(680),
            maxWidth: InterfaceScale.metric(760),
            minHeight: InterfaceScale.metric(440),
            idealHeight: InterfaceScale.metric(520),
            maxHeight: InterfaceScale.metric(640)
        )
    }
}

struct ForumActionErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: InterfaceScale.metric(10)) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.interface(.callout))
                .lineLimit(2)
            Spacer(minLength: InterfaceScale.metric(8))
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .help("Dismiss error")
        }
        .padding(.horizontal, InterfaceScale.metric(14))
        .padding(.vertical, InterfaceScale.metric(9))
        // Glass of its own: the forum header has no backdrop, and posts
        // scroll beneath the banner.
        .glassEffect(
            .regular.tint(Color.red.opacity(0.2)),
            in: RoundedRectangle(cornerRadius: InterfaceScale.metric(14), style: .continuous)
        )
        .padding(.horizontal, InterfaceScale.metric(14))
        .padding(.bottom, InterfaceScale.metric(8))
        .accessibilityElement(children: .contain)
    }
}

struct ForumEmptyState: View {
    let title: String
    let description: String
    let systemImage: String

    var body: some View {
        VStack(spacing: InterfaceScale.metric(10)) {
            Image(systemName: systemImage)
                .font(.interfaceSystem(size: 34, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.interface(.headline))
            Text(description)
                .font(.interface(.callout))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, InterfaceScale.metric(24))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
