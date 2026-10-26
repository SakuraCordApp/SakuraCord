import DiscordProtocol
import SakuraCordModels
import SwiftUI

enum MessagePeoplePopoverLayout {
    static var size: CGSize { CGSize(width: InterfaceScale.metric(540), height: InterfaceScale.metric(420)) }
}

struct MessagePeoplePopover<Selection: Hashable, Header: View, Categories: View>: View {
    let model: AppModel
    let message: Message
    let selection: Selection?
    let count: Int?
    let pager: MessagePeoplePager<Selection>
    let emptyTitle: LocalizedStringKey
    let errorTitle: LocalizedStringKey
    let systemImage: String
    var sidebarWidth: CGFloat = 220
    var displayedUsers: ([User]) -> [User] = { $0 }
    let fetch: @MainActor (any ChatProvider, Selection, UserID?) async throws -> MessagePeoplePage
    @ViewBuilder let header: Header
    @ViewBuilder let categories: Categories

    private struct LoadIdentity: Equatable {
        var selection: Selection?
        var count: Int?
        var revision: UInt64
        var generation: UInt64
        var accountID: UserID?
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, InterfaceScale.metric(20)).padding(.vertical, InterfaceScale.metric(16))
            Divider()
            HStack(spacing: 0) {
                ScrollView(.vertical) {
                    VStack(spacing: InterfaceScale.metric(2)) { categories }
                        .padding(InterfaceScale.metric(8))
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: InterfaceScale.metric(sidebarWidth))
                Divider()
                peopleList.frame(maxWidth: .infinity)
            }
        }
        .frame(width: MessagePeoplePopoverLayout.size.width, height: MessagePeoplePopoverLayout.size.height)
        .task(id: LoadIdentity(selection: selection, count: count,
                               revision: selection.flatMap { pager.revisions[$0] } ?? 0,
                               generation: pager.generation,
                               accountID: model.currentUser?.id)) {
            guard let selection else { return }
            let page = pager.pages[selection]
            let wasInvalidated = pager.revisions[selection] != nil || pager.generation > 0
            if (page != nil && page?.count != count) || (page == nil && wasInvalidated) {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
            }
            load(selection, after: nil)
        }
        .onDisappear { pager.reset() }
    }

    private var peopleList: some View {
        let page = selection.flatMap { pager.pages[$0] }
        let error = selection.flatMap { pager.errors[$0] }
        let users = displayedUsers(page?.users ?? [])
        let guildID = model.messagePresentationGuildID(for: message)
        return ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: InterfaceScale.metric(2)) {
                ForEach(users) { user in
                    MessagePersonRow(model: model, user: user, guildID: guildID)
                }
                if let selection, let page {
                    if let error {
                        VStack(spacing: InterfaceScale.metric(6)) {
                            Text(error).font(.interface(.caption)).foregroundStyle(.secondary)
                            Button("Try Again") {
                                load(selection, after: page.count == count ? page.cursor : nil)
                            }
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, InterfaceScale.metric(8))
                    } else if page.hasMore {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, InterfaceScale.metric(8))
                            .id(page.cursor)
                            .onAppear { load(selection, after: page.cursor) }
                    }
                }
            }
            .padding(InterfaceScale.metric(8))
        }
        .id(selection)
        .scrollBounceBehavior(.basedOnSize)
        .overlay {
            if page == nil, let error, let selection {
                ContentUnavailableView {
                    Label(errorTitle, systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { load(selection, after: nil) }.buttonStyle(.glass)
                }
            } else if !users.isEmpty {
                EmptyView()
            } else if selection != nil, page == nil, count != 0 {
                ProgressView().controlSize(.small)
            } else {
                ContentUnavailableView(emptyTitle, systemImage: systemImage)
            }
        }
    }

    private func load(_ selection: Selection, after: UserID?) {
        let session = model.accountSession()
        pager.load(selection, count: count, after: after, isCurrent: { model.isCurrentAccountSession(session) }, fetch: { cursor in
            try await fetch(session.provider, selection, cursor)
        })
    }
}

private struct MessagePersonRow: View {
    let model: AppModel
    let user: User
    let guildID: GuildID?

    var body: some View {
        let member = guildID.flatMap { guildID in
            model.membersByGuildID[guildID]?[user.id]
                ?? (guildID == model.selectedGuildID ? model.membersByID[user.id] : nil)
        }
        let isCurrentUser = model.currentUser?.id == user.id
        HStack(spacing: InterfaceScale.metric(10)) {
            AvatarView(name: user.displayName, url: member?.guildAvatarURL ?? user.avatarURL, size: InterfaceScale.metric(32))
            VStack(alignment: .leading, spacing: 1) {
                Text(member?.user.displayName ?? user.displayName).font(.interface(.callout).weight(.medium)).lineLimit(1)
                Text(user.username).font(.interface(.caption)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: InterfaceScale.metric(8))
            if isCurrentUser {
                Text("You").font(.interface(.caption).weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, InterfaceScale.metric(10)).padding(.vertical, InterfaceScale.metric(6))
        .accessibilityElement(children: .combine)
    }
}
