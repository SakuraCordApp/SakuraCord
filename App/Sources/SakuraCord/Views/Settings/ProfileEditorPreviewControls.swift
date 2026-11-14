import AppKit
import SakuraCordModels
import SwiftUI

struct ProfileEditorImageMenu: ViewModifier {
    enum Target { case avatar, banner }

    let editor: ProfileEditorState?
    let target: Target
    let open: ((ProfileEditorPicker) -> Void)?
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false
    @State private var picker: ProfileEditorPicker?

    func body(content: Content) -> some View {
        let showsEditAffordance = isHovered && isEnabled && editor?.displayProfile != nil && open != nil
        content
            .brightness(showsEditAffordance ? -0.45 : 0)
            .overlay {
                if editor?.displayProfile != nil, open != nil {
                    HoverActionPill {
                        HoverActionControlLabel { Image(systemName: "pencil").font(.interface(.callout).weight(.medium)) }
                    }
                        .anchorPreference(key: ProfileImageEditAnchorKey.self, value: .bounds) { $0 }
                        .padding(target == .banner ? InterfaceScale.metric(12) : 0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: target == .avatar ? .center : .topTrailing)
                        .opacity(showsEditAffordance ? 1 : 0)
                        .allowsHitTesting(false)
                }
            }
            .overlayPreferenceValue(ProfileImageEditAnchorKey.self) { anchor in
                if let editor, let profile = editor.displayProfile, let anchor, open != nil {
                    GeometryReader { geometry in
                        ProfileImageMenuButton(editor: editor, target: target, editBounds: geometry[anchor], open: { picker = $0 })
                            .modifier(ProfileEditorPickerPopover(selection: $picker, editor: editor, profile: profile))
                    }
                }
            }
            .animation(.easeOut(duration: 0.12), value: showsEditAffordance)
            // Clipping the artwork does not constrain its overflow hit area.
            .contentShape(Rectangle())
            .onModalHover { isHovered = $0 }
    }
}

private struct ProfileImageEditAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) { value = nextValue() ?? value }
}

/// AppKit owns menu tracking only. Keeping the transparent button above the
/// SwiftUI artwork avoids NSMenu's restricted label rendering on macOS.
private struct ProfileImageMenuButton: NSViewRepresentable {
    let editor: ProfileEditorState
    let target: ProfileEditorImageMenu.Target
    let editBounds: CGRect
    let open: (ProfileEditorPicker) -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(bridge: self) }

    func makeNSView(context: Context) -> MenuButton {
        let button = MenuButton(title: "", target: context.coordinator, action: #selector(Coordinator.showMenu(_:)))
        button.isBordered = false
        button.isTransparent = true
        button.setButtonType(.momentaryPushIn)
        button.focusRingType = .exterior
        return button
    }

    func updateNSView(_ button: MenuButton, context: Context) {
        context.coordinator.bridge = self
        button.editBounds = editBounds
        button.isEnabled = isEnabled
        button.setAccessibilityLabel(target == .avatar ? String(localized: "Edit Avatar and Decoration", bundle: #bundle) : String(localized: "Edit Banner and Effect", bundle: #bundle))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MenuButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    final class MenuButton: NSButton {
        var editBounds: CGRect = .zero
        override var isFlipped: Bool { true }

        override func mouseDown(with event: NSEvent) { openMenu(with: event) }
        override func rightMouseDown(with event: NSEvent) { openMenu(with: event) }

        private func openMenu(with event: NSEvent) {
            // AppKit can deliver a later click in a multi-click sequence to the
            // original button. The avatar overlaps the banner, so testing only
            // our bounds still accepts an avatar click on the banner button.
            guard let window, event.window === window, let content = window.contentView else { return }
            let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
            var hit = content.hitTest(point)
            while let view = hit {
                if let button = view as? MenuButton {
                    guard button.isEnabled else { return }
                    button.sendAction(button.action, to: button.target)
                    return
                }
                hit = view.superview
            }
        }
    }

    final class Coordinator: NSObject {
        var bridge: ProfileImageMenuButton
        private var isTrackingMenu = false

        init(bridge: ProfileImageMenuButton) {
            self.bridge = bridge
        }

        @objc func showMenu(_ sender: MenuButton) {
            let editor = bridge.editor
            let open = bridge.open
            guard sender.isEnabled, !editor.isSaving, !editor.requiresReload, !isTrackingMenu else { return }
            isTrackingMenu = true
            defer { isTrackingMenu = false }
            let menu = NSMenu()
            switch bridge.target {
            case .avatar:
                if editor.scope == .main || editor.isNitro {
                    add(String(localized: "Change Avatar", bundle: #bundle), to: menu, systemImage: "person.crop.circle") { [open] in open(.avatar) }
                }
                add(String(localized: "Change Avatar Decoration", bundle: #bundle), to: menu, systemImage: "person.crop.circle.badge.plus") { [open] in open(.collectible(.avatarDecoration)) }
                if editor.hasAvatarSelection || editor.selectedCollectibleID(.avatarDecoration) != nil { menu.addItem(.separator()) }
                if editor.hasAvatarSelection {
                    add(String(localized: "Remove Avatar", bundle: #bundle), to: menu, destructive: true) { [editor] in editor.setAvatar(nil) }
                }
                if editor.selectedCollectibleID(.avatarDecoration) != nil {
                    add(editor.collectibleRemovalTitle(.avatarDecoration), to: menu, destructive: true) { [editor] in editor.setCollectible(nil, kind: .avatarDecoration) }
                }
            case .banner:
                if editor.isNitro { add(String(localized: "Change Banner", bundle: #bundle), to: menu, systemImage: "photo") { [open] in open(.banner) } }
                add(String(localized: "Change Profile Effect", bundle: #bundle), to: menu, systemImage: "sparkles") { [open] in open(.collectible(.effect)) }
                add(String(localized: "Change Profile Frame", bundle: #bundle), to: menu, systemImage: "rectangle.inset.filled") { [open] in open(.collectible(.frame)) }
                if editor.hasBannerSelection || editor.selectedCollectibleID(.effect) != nil || editor.selectedCollectibleID(.frame) != nil { menu.addItem(.separator()) }
                if editor.hasBannerSelection {
                    add(String(localized: "Remove Banner", bundle: #bundle), to: menu, destructive: true) { [editor] in editor.setBanner(nil) }
                }
                for kind in [ProfileCollectibleKind.effect, .frame] where editor.selectedCollectibleID(kind) != nil {
                    add(editor.collectibleRemovalTitle(kind), to: menu, destructive: true) { [editor] in editor.setCollectible(nil, kind: kind) }
                }
            }
            menu.popUp(positioning: nil, at: NSPoint(x: sender.editBounds.maxX + 6, y: sender.editBounds.minY), in: sender)
        }

        private func add(_ title: String, to menu: NSMenu, systemImage: String = "trash", destructive: Bool = false, action: @escaping () -> Void) {
            menu.addItem(ContextMenuItemSupport.item(title, systemImage: systemImage, isDestructive: destructive) { [self] in
                let editor = bridge.editor
                guard !editor.isSaving, !editor.isLoading, !editor.requiresReload else { return }
                action()
            })
        }
    }
}

// Removal captions describe the raw scoped selection, even when the preview
// resolves a main-profile fallback after the selection is cleared.
extension ProfileEditorState {
    func collectibleRemovalTitle(_ kind: ProfileCollectibleKind) -> String {
        switch kind {
        case .avatarDecoration:
            return scope == .main ? String(localized: "Remove Avatar Decoration", bundle: #bundle) : String(localized: "Reset avatar decoration to default", bundle: #bundle)
        case .nameplate:
            return scope == .main ? String(localized: "Remove Nameplate", bundle: #bundle) : String(localized: "Reset nameplate to default", bundle: #bundle)
        case .effect:
            return scope == .main ? String(localized: "Remove Profile Effect", bundle: #bundle) : String(localized: "Reset Effect", bundle: #bundle)
        case .frame:
            return scope == .main ? String(localized: "Remove Profile Frame", bundle: #bundle) : String(localized: "Reset Frame", bundle: #bundle)
        }
    }
}
