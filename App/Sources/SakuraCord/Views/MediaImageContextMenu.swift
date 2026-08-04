import AppKit
import SakuraCordModels
import SwiftUI

struct MediaImageContextMenuActions {
    let copyImage: () -> Void
    let saveImage: () -> Void
    let copyLink: () -> Void
    let openLink: () -> Void
}

@MainActor
enum MediaImageContextMenuBuilder {
    static func make(actions: MediaImageContextMenuActions) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(
            actionItem(
                "Copy Image",
                systemImage: "document.on.document.fill",
                action: actions.copyImage
            )
        )
        menu.addItem(
            actionItem(
                "Save Image",
                systemImage: "arrow.down.to.line",
                action: actions.saveImage
            )
        )
        menu.addItem(.separator())
        menu.addItem(
            actionItem(
                "Copy Image Link",
                systemImage: "link",
                action: actions.copyLink
            )
        )
        menu.addItem(
            actionItem(
                "Open Image Link",
                systemImage: "arrow.up.forward.app",
                action: actions.openLink
            )
        )
        return menu
    }

    private static func actionItem(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> NSMenuItem {
        let target = NativeTimelineMenuAction(action)
        let item = NSMenuItem(
            title: title,
            action: #selector(NativeTimelineMenuAction.performAction),
            keyEquivalent: ""
        )
        item.target = target
        item.representedObject = target
        item.isEnabled = true
        ContextMenuItemSupport.configure(
            item,
            title: title,
            systemImage: systemImage
        )
        return item
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
        let isSecondaryClick = event.type == .rightMouseDown
            || (event.type == .leftMouseDown
                && event.modifierFlags.contains(.control))
        return isSecondaryClick ? self : nil
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
            if let region = component.images.first(where: {
                $0.frame.contains(point)
            }) {
                guard !region.isSpoiler || isRevealed(region.componentID) else {
                    return nil
                }
                return RichMediaItem(
                    imageID: region.componentID,
                    url: region.openURL,
                    previewURL: region.displayURL == region.openURL
                        ? nil
                        : region.displayURL,
                    title: region.description
                )
            }
            if let region = component.media.first(where: {
                $0.frame.contains(point) && !$0.isVideo
            }) {
                guard !region.isSpoiler || isRevealed(region.componentID) else {
                    return nil
                }
                return RichMediaItem(
                    imageID: region.componentID,
                    url: region.openURL,
                    previewURL: region.displayURL == region.openURL
                        ? nil
                        : region.displayURL,
                    title: region.description
                )
            }
        }
        return nil
    }
}
