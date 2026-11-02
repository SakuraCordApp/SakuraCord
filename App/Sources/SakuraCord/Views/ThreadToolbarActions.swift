import AppKit
import SakuraCordModels
import SwiftUI

/// The open thread's overflow menu in the window toolbar: the side chat's
/// pane menu, or the full view's.
/// It opens the same AppKit menu as the channel list's thread menu, so item
/// icons, subtitles and destructive tints match the app's other menus.
struct ThreadActionsToolbarMenu: View {
    let model: AppModel
    let thread: MessageThreadSummary
    let surface: ThreadActionSurface
    @State private var presenter = ThreadActionsMenuPresenter()

    var body: some View {
        Button {
            presenter.show(ThreadActionsMenu(model: model, thread: thread, surface: surface))
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .help(model.isForumThread(thread) ? "More post actions" : "More thread actions")
        .background { ThreadActionsMenuAnchor(presenter: presenter) }
    }
}

/// Pops a thread's AppKit menu below the view it is anchored to, and keeps
/// the renderer, which owns the item actions, alive while the menu is open.
@MainActor
final class ThreadActionsMenuPresenter {
    weak var anchor: NSView?
    private let renderer = ThreadActionsMenuRenderer()

    func show(_ actionsMenu: ThreadActionsMenu) {
        guard let anchor else { return }
        renderer.makeMenu(actionsMenu).popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: anchor)
    }
}

struct ThreadActionsMenuAnchor: NSViewRepresentable {
    let presenter: ThreadActionsMenuPresenter

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        presenter.anchor = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        presenter.anchor = nsView
    }
}

/// The open forum post's Follow toggle: an icon button that stays selected
/// while the post is followed, like the toolbar's other toggles.
struct ForumPostFollowToolbarButton: View {
    let model: AppModel
    let thread: MessageThreadSummary
    let surface: ThreadActionSurface

    var body: some View {
        let thread = model.currentThreadSummary(thread)
        let isFollowing = thread.notificationSettings != nil
        Toggle(isOn: Binding(
            get: { isFollowing },
            set: { model.setThreadMembership(thread, isJoined: $0, surface: surface) }
        )) {
            Label(isFollowing ? "Unfollow Post" : "Follow Post", systemImage: "bell")
                .symbolVariant(isFollowing ? .fill : .none)
                .labelStyle(.iconOnly)
        }
        .toggleStyle(.button)
        .disabled(!model.threadActionPolicy(thread).canChangeMembership)
        .help(
            isFollowing
                ? "Unfollow Post: you're following this post and get notifications about it."
                : "Follow Post: add this post to your channel list and get notifications about it."
        )
        .accessibilityLabel(isFollowing ? "Unfollow Post" : "Follow Post")
        .accessibilityValue(isFollowing ? "Following" : "Not following")
    }

    static func isOffered(model: AppModel, thread: MessageThreadSummary) -> Bool {
        model.isForumThread(thread) && model.threadActionPolicy(thread).canRead
    }
}
