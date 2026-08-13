import DiscordProtocol
import Foundation
import SakuraCordModels

@MainActor
extension AppModel {
    func presentQuickSwitcher() {
        guard sessionState == .workspace else { return }
        if workspaceNavigationOverlay == .quickSwitcher {
            dismissWorkspaceNavigationOverlay()
            return
        }
        AppPerformanceSignposts.beginQuickSwitcherOpen()
        workspaceNavigationOverlay = .quickSwitcher
    }

    func presentMessageSearch() {
        guard sessionState == .workspace, selectedChannelID != nil else { return }
        workspaceNavigationOverlay = .messageSearch
    }

    func dismissWorkspaceNavigationOverlay() {
        if workspaceNavigationOverlay == .quickSwitcher {
            AppPerformanceSignposts.beginQuickSwitcherClose()
        }
        workspaceNavigationOverlay = nil
    }

    func activateQuickSwitcherDestination(_ destination: ForwardDestination) {
        switch destination.kind {
        case .channel(let channel):
            workspaceNavigationOverlay = nil
            navigate(to: channel.id)
        case .thread(let thread, _):
            workspaceNavigationOverlay = nil
            navigate(to: thread.guildID, linkedChannelID: thread.id)
        case .user(let user, let directMessage):
            if let directMessage {
                workspaceNavigationOverlay = nil
                navigate(to: directMessage.id)
                return
            }
            workspaceNavigationOverlay = nil
            let session = accountSession()
            startAccountChildTask(account: session) { model, session in
                do {
                    let channel = try await session.provider.ensurePrivateChannel(for: user.id)
                    guard model.isCurrentAccountSession(session) else { return }
                    if model.snapshot?.channels.contains(where: { $0.id == channel.id }) == false {
                        model.snapshot?.channels.append(channel)
                        model.forwardSearchSourceRevision &+= 1
                    }
                    model.navigate(to: channel.id)
                } catch {
                    guard model.isCurrentAccountSession(session) else { return }
                    model.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func searchSelectedChannelMessages(
        query: String,
        limit: Int = 25,
        offset: Int = 0
    ) async throws -> MessageSearchPage {
        guard let channelID = selectedChannelID else {
            throw ChatProviderError.channelNotFound
        }
        let session = accountSession()
        let page = try await session.provider.searchMessages(
            in: channelID,
            query: query,
            limit: limit,
            offset: offset
        )
        guard isCurrentAccountSession(session), selectedChannelID == channelID else {
            throw CancellationError()
        }
        return page
    }

    func navigateToSearchResult(_ message: Message) {
        let guildID = message.guildID
            ?? snapshot?.channels.first(where: { $0.id == message.channelID })?.guildID
        workspaceNavigationOverlay = nil
        navigate(
            to: guildID,
            channelID: message.channelID,
            messageID: message.id
        )
    }
}
