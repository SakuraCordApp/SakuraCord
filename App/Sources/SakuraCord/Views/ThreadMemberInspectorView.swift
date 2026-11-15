import SakuraCordModels
import SwiftUI

struct ThreadMemberInspectorView: View {
    let model: AppModel
    let thread: MessageThreadSummary
    @State private var errorMessage: String?

    private var requestIdentity: String {
        "\(thread.id):\(thread.isArchived):\(model.openThreadAccess.isReadable):\(model.currentUser?.id.description ?? "")"
    }

    var body: some View {
        Group {
            if !model.openThreadAccess.isReadable {
                ContentUnavailableView("Members unavailable", systemImage: "lock.fill")
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Couldn’t load members", systemImage: "person.2")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            } else if thread.isArchived || model.threadMembersByID[thread.id]?.isEmpty == true {
                ContentUnavailableView("No members to show", systemImage: "person.2")
            } else if let members = model.threadMembersByID[thread.id] {
                MemberInspectorView(
                    sections: MemberSection.make(from: model.membersWithCurrentStatus(members), forThread: true),
                    customEmojiURLsByID: model.customEmojiURLsByID,
                    profilePresentation: model.liveProfilePresentation(for: .inspector),
                    isProfilePresented: model.isInspectorProfilePresented,
                    selectMember: model.selectMember,
                    dismissProfile: model.dismissInspectorProfile,
                    viewportIdentity: thread.id,
                    presentation: NativeMemberListPresentation(roleColorDisplay: model.accessibilitySettings.roleColorDisplay),
                    openProfile: model.expandProfile,
                    userMenu: { UserContextMenu.make(for: $0.user, context: .init(guildID: thread.guildID, channelID: thread.id), model: model) },
                    userAccessibilityActions: { UserContextMenu.accessibilityActions(for: $0.user, context: .init(guildID: thread.guildID, channelID: thread.id), model: model) },
                    updateViewport: { _ in }
                )
            } else {
                MemberListLoadingSkeleton()
            }
        }
        .task(id: requestIdentity) { await load() }
    }

    private func load() async {
        errorMessage = nil
        do {
            try await model.loadThreadMembers(thread)
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, model.openThread?.id == thread.id else { return }
            errorMessage = error.localizedDescription
        }
    }
}
