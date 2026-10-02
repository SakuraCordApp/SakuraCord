import AppKit
import SakuraCordModels

@MainActor
enum MemberContextMenu {
    static func make(for member: Member, model: AppModel) -> NSMenu {
        let menu = NSMenu()
        add("Profile", symbol: "person.crop.circle", to: menu) {
            model.presentProfile(for: member, destination: .expanded)
            model.dismissContextualProfile()
            model.dismissInspectorProfile()
        }
        if model.selectedChannel != nil {
            add("Mention", symbol: "at", to: menu) {
                let separator = model.draft.isEmpty || model.draft.last?.isWhitespace == true ? "" : " "
                model.rememberMentionMember(member)
                model.updateDraft(model.draft + separator + "<@\(member.id)> ")
                NotificationCenter.default.post(
                    name: .sakuracordFocusComposer,
                    object: MessageComposerDestination.channel,
                    userInfo: ["selection": NSRange(location: model.draft.utf16.count, length: 0)]
                )
            }
        }
        if member.id != model.snapshot?.currentUser.id {
            add("Message", symbol: "bubble.left", to: menu) {
                model.activateQuickSwitcherDestination(ForwardDestination(kind: .user(member.user, directMessage: nil), guild: nil))
            }
        }
        menu.addItem(.separator())
        add("Copy User ID", symbol: "number", to: menu) {
            ChannelContextMenuValue.copy(member.id.description)
        }
        return menu
    }

    private static func add(_ title: String, symbol: String, to menu: NSMenu, action: @escaping () -> Void) {
        let target = NativeTimelineMenuAction(action)
        let item = NSMenuItem(title: title, action: #selector(NativeTimelineMenuAction.performAction), keyEquivalent: "")
        item.target = target
        item.representedObject = target
        ContextMenuItemSupport.configure(item, title: title, systemImage: symbol)
        menu.addItem(item)
    }
}
