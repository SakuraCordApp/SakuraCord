import AppKit
import SakuraCordModels
import SwiftUI

struct MediaImageContextMenuActions {
    let copyImage: () -> Void
    let save: MediaSaveMenuActions
    let copyLink: () -> Void
    let openLink: () -> Void
}

@MainActor
enum MediaImageContextMenuBuilder {
    static func make(
        actions: MediaImageContextMenuActions,
        includesLinkActions: Bool = true
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        appendImageActions(
            to: menu,
            actions: actions,
            includesLinkActions: includesLinkActions
        )
        return menu
    }

    static func appendImageActions(
        to menu: NSMenu,
        actions: MediaImageContextMenuActions,
        includesLinkActions: Bool
    ) {
        menu.addItem(
            ContextMenuItemSupport.item(
                "Copy Image",
                systemImage: "document.on.document.fill",
                action: actions.copyImage
            )
        )
        menu.addItem(
            MediaSaveMenuBuilder.submenuItem(
                "Save Image",
                systemImage: "arrow.down.to.line",
                actions: actions.save
            )
        )
        guard includesLinkActions else { return }
        menu.addItem(.separator())
        menu.addItem(
            ContextMenuItemSupport.item(
                "Copy Image Link",
                systemImage: "link",
                action: actions.copyLink
            )
        )
        menu.addItem(
            ContextMenuItemSupport.item(
                "Open Image Link",
                systemImage: "arrow.up.forward.app",
                action: actions.openLink
            )
        )
    }

}

/// A right-click-only AppKit surface. Primary clicks pass through to the
/// SwiftUI image gestures while secondary clicks use SakuraCord's native menu
/// path, including forced-visible SF Symbol icons on macOS 27.
struct MediaImageContextMenuBridge: NSViewRepresentable {
    let actions: MediaImageContextMenuActions

    func makeCoordinator() -> Coordinator {
        Coordinator(actions: actions)
    }

    func makeNSView(context: Context) -> MediaImageContextMenuHitView {
        let view = MediaImageContextMenuHitView()
        view.menuProvider = { [weak coordinator = context.coordinator] in
            coordinator?.makeMenu()
        }
        return view
    }

    func updateNSView(
        _ nsView: MediaImageContextMenuHitView,
        context: Context
    ) {
        context.coordinator.actions = actions
    }

    @MainActor
    final class Coordinator {
        var actions: MediaImageContextMenuActions

        init(actions: MediaImageContextMenuActions) {
            self.actions = actions
        }

        func makeMenu() -> NSMenu {
            MediaImageContextMenuBuilder.make(actions: actions)
        }
    }
}

@MainActor
final class MediaImageContextMenuHitView: NSView {
    var menuProvider: (() -> NSMenu?)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point), let event = NSApp.currentEvent else {
            return nil
        }
        return event.isContextClick ? self : nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?()
    }

    override func isAccessibilityElement() -> Bool {
        false
    }
}

@MainActor
enum NativeTimelineImageContextMenuPlan {
    static func item(
        in message: Message,
        layout: NativeTimelineRowLayout,
        at point: CGPoint,
        isRevealed: (String) -> Bool
    ) -> RichMediaItem? {
        if let region = layout.linkedImageRegions.first(where: {
            $0.frame.contains(point)
        }) {
            return RichMediaItem(
                imageID: region.reference.id,
                url: region.reference.url,
                title: region.reference.label
            )
        }

        if let attachment = layout.attachmentRegions.first(where: {
            $0.frame.contains(point)
        })?.attachment,
           attachment.mediaKind == .image
            || attachment.mediaKind == .animatedImage
        {
            let componentID = NativeTimelineComponentRevealKey
                .attachmentComponentID(attachment.id)
            guard !attachment.isSpoiler || isRevealed(componentID) else {
                return nil
            }
            return RichMediaItem(attachment)
        }

        if let embedRegion = layout.embedRegions.first(where: {
            $0.mediaFrame?.contains(point) == true && !$0.mediaIsVideo
        }),
           let embed = message.embeds.first(where: {
               $0.id == embedRegion.embedID
           }),
           let item = RichMediaItem(
               embed: embed,
               attachments: message.attachments
           ),
           case .image = item.kind
        {
            if item.isSpoiler {
                let componentID = NativeTimelineComponentRevealKey
                    .attachmentComponentID(item.id)
                guard isRevealed(componentID) else { return nil }
            }
            return item
        }

        for component in layout.componentLayouts {
            if component.containers.contains(where: {
                $0.isSpoiler
                    && $0.frame.contains(point)
                    && !isRevealed($0.componentID)
            }) {
                return nil
            }
            for region in component.mediaRegions where region.frame.contains(point) {
                let displayURL: URL
                let description: String
                switch region.kind {
                case let .image(image):
                    (displayURL, description) = (image.displayURL, image.description)
                case let .media(media) where !media.isVideo:
                    (displayURL, description) = (media.displayURL, media.description)
                case .media, .file:
                    continue
                }
                guard !region.isSpoiler || isRevealed(region.componentID) else {
                    return nil
                }
                return RichMediaItem(
                    imageID: region.componentID,
                    url: region.openURL,
                    previewURL: displayURL == region.openURL
                        ? nil
                        : displayURL,
                    title: description
                )
            }
        }
        return nil
    }
}
