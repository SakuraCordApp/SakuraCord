import AppKit
import SakuraCordModels
import SwiftUI

struct ApplicationCommandPickerView: View {
    let composer: ApplicationCommandComposerModel
    let choose: (ApplicationCommand) -> Void
    let dismiss: () -> Void
    var cornerRadius: CGFloat = ChatChromeMetrics.composerCornerRadius
    @State private var visibleSection: String?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let sections = composer.pickerSections
        let selectedRowID = composer.selectedRowID
        NativePickerScrollReader { proxy in
            HStack(spacing: 0) {
                if sections.count > 1, sections.first?.kind != .searchResults {
                    PickerSectionRail {
                        ForEach(sections) { section in
                            PickerSectionBookmark(
                                section: CommandRailSection(id: section.id),
                                visibleSection: CommandRailSection(id: visibleSection ?? sections.first?.id ?? ""),
                                help: section.title,
                                jump: { _ in
                                    visibleSection = section.id
                                    proxy.scrollTo("command-header:\(section.id)", anchor: .top)
                                },
                                content: {
                                if section.kind == .frequentlyUsed {
                                    Image(nsImage: CommandGeneratedIcon.image(symbol: "clock.fill", size: PickerSectionRailLayout.iconSize, colorScheme: colorScheme, scale: displayScale))
                                        .renderingMode(.original)
                                } else {
                                    CommandApplicationIcon(application: section.application, size: PickerSectionRailLayout.iconSize, isBookmark: true)
                                }
                                }
                            )
                            if section.kind == .frequentlyUsed {
                                Divider().frame(width: InterfaceScale.metric(28)).padding(.vertical, InterfaceScale.metric(2))
                            }
                        }
                    }
                    Divider()
                }
                if sections.isEmpty {
                    status.frame(maxWidth: .infinity, minHeight: InterfaceScale.metric(64))
                } else {
                    NativePickerDocument(
                        rows: composer.pickerDocumentRows,
                        revision: composer.pickerDocumentRevision,
                        position: proxy,
                        capturesOverlayPointer: true,
                        rowHeight: { row, _ in row.height },
                        pinnedHeader: { $0.command == nil },
                        topVisibleRowChanged: { row in
                            if visibleSection != row.sectionID { visibleSection = row.sectionID }
                        },
                        pointerRowChanged: { row in
                            if row.command != nil, composer.selectedRowID != row.id { composer.selectedRowID = row.id }
                        },
                        nativeContent: { row, reused, environment in
                            let view = reused as? NativeCommandPickerRow ?? NativeCommandPickerRow()
                            view.configure(row, selected: row.id == selectedRowID,
                                cornerRadius: max(0, cornerRadius - 6), colorScheme: environment.colorScheme,
                                choose: choose, highlight: { composer.selectedRowID = $0 })
                            return view
                        },
                        content: { _ in EmptyView() }
                    )
                    .frame(height: min(348, composer.pickerDocumentHeight))
                    .padding(.horizontal, InterfaceScale.metric(6))
                }
            }
            .onChange(of: composer.pickerKeyboardSelectionRevision) { _, _ in
                // The highlight stops short of the edges, concentric with the panel.
                if let id = composer.selectedRowID { proxy.scrollTo(id, edgeInset: InterfaceScale.metric(6)) }
            }
            .onChange(of: composer.pickerDocumentRevision, initial: true) { _, _ in
                visibleSection = sections.first?.id
                if let id = composer.pickerDocumentRows.first?.id { proxy.scrollTo(id, anchor: .top) }
            }
        }
        .frame(maxWidth: .infinity)
        .commandPanelSurface(cornerRadius: cornerRadius)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Application commands")
        .onExitCommand(perform: dismiss)
    }

    @ViewBuilder private var status: some View {
        if composer.isLoading {
            HStack(spacing: InterfaceScale.metric(8)) { InteractionLoadingDotsView(); Text("Loading commands…") }
                .foregroundStyle(.secondary)
        } else if let error = composer.loadError {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
        } else {
            Text("No commands match “\(composer.searchText)”").foregroundStyle(.secondary)
        }
    }
}

private struct CommandRailSection: Identifiable, Hashable { let id: String }

extension View {
    func commandPanelSurface(cornerRadius: CGFloat) -> some View {
        clipShape(.rect(cornerRadius: cornerRadius))
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
            .containerShape(.rect(cornerRadius: cornerRadius))
    }
}

/// The active command's application, shown at the start of the composer.
struct ApplicationCommandComposerBadge: View {
    let command: ApplicationCommand
    let cancel: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: cancel) {
            ZStack {
                CommandApplicationIcon(application: command.application, size: InterfaceScale.metric(24))
                    .opacity(isHovered ? 0 : 1)
                Image(systemName: "xmark")
                    .font(.interfaceSystem(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .opacity(isHovered ? 1 : 0)
            }
            .frame(width: ChatChromeMetrics.composerControlHeight, height: ChatChromeMetrics.composerControlHeight)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onModalHover { isHovered = $0 }
        .help("Cancel /\(command.displayName)")
        .accessibilityLabel("Cancel command")
    }
}

struct CommandApplicationIcon: View {
    let application: ApplicationCommandApplication?
    let size: CGFloat
    var isBookmark = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if application?.id == SakuraCordBuiltInCommands.application.id {
                Image(nsImage: CommandGeneratedIcon.sakuraFlower)
                    .resizable()
                    .scaledToFit()
            } else if application?.id == DiscordBuiltInCommands.application.id {
                Image(nsImage: CommandGeneratedIcon.image(symbol: "slash.circle.fill", size: size, colorScheme: colorScheme, scale: displayScale))
                    .renderingMode(.original)
            } else if let url = application?.displayIconURL {
                if isBookmark {
                    StaticRemoteImage(url: url, maximumPixelDimension: 64)
                } else {
                    AnimatedRemoteImage(url: url)
                }
            } else {
                Image(nsImage: CommandGeneratedIcon.image(
                    initials: application.map { String($0.name.prefix(2)).uppercased() } ?? "/",
                    size: size, colorScheme: colorScheme, scale: displayScale
                ))
                .renderingMode(.original)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: isBookmark ? 8 : size / 2))
        .accessibilityHidden(true)
    }
}

/// Resolve generated artwork before it enters the glass foreground, just like
/// downloaded avatars. The bounded cache avoids rasterizing during scrolling.
@MainActor enum CommandGeneratedIcon {
    static let sakuraFlower: NSImage = {
        guard let url = Bundle.module.url(forResource: "SakuraCord-Flower-Transparent-Liquid-128", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return NSImage() }
        image.isTemplate = false
        return image
    }()

    private static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 128
        return cache
    }()

    static func image(symbol: String? = nil, initials: String = "", size: CGFloat,
                      colorScheme: ColorScheme, scale: CGFloat) -> NSImage {
        let key = "\(symbol ?? initials):\(size):\(colorScheme):\(scale)" as NSString
        if let image = images.object(forKey: key) { return image }
        let foreground: Color = colorScheme == .dark ? .white : .black
        let content = ZStack {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: size * (symbol == "slash.circle.fill" ? 0.65 : 0.48)))
                    .foregroundStyle(foreground.opacity(0.85))
            } else {
                foreground.opacity(0.08)
                Text(initials)
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(foreground.opacity(0.85))
            }
        }
        .frame(width: size, height: size)
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        guard let bitmap = renderer.cgImage else { return NSImage(size: NSSize(width: size, height: size)) }
        let image = NSImage(cgImage: bitmap, size: NSSize(width: size, height: size))
        image.isTemplate = false
        images.setObject(image, forKey: key)
        return image
    }
}

extension Channel {
    var discordCommandType: Int {
        switch kind {
        case .text: 0
        case .directMessage: 1
        case .voice: 2
        case .groupDirectMessage: 3
        case .announcement: 5
        case .forum: 15
        case .unknown: -1
        }
    }
}
