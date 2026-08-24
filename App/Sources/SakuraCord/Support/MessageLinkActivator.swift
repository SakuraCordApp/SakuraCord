import Foundation
import MessageRendering

@MainActor
enum MessageLinkActivator {
    static func activate(
        _ url: URL,
        model: AppModel?,
        displayedText: String? = nil,
        customHandler: (URL) -> Bool = { _ in false },
        confirmExternal: (ExternalLinkSafetyAssessment) -> Void = {
            ExternalLinkConfirmationPresenter.shared.present($0)
        }
    ) -> Bool {
        guard let destination = MessageLinkPolicy.destination(for: url) else {
            return true
        }
        switch destination {
        case let .discordChannel(guildID, channelID):
            if let model, model.chatSettings.opensDiscordLinksInternally {
                model.navigate(to: guildID, linkedChannelID: channelID)
            } else if !customHandler(url) {
                confirmExternal(
                    ExternalLinkSafetyPolicy.assess(
                        url,
                        displayedText: displayedText
                    )
                )
            }
        case .web:
            if !customHandler(url) {
                confirmExternal(
                    ExternalLinkSafetyPolicy.assess(
                        url,
                        displayedText: displayedText
                    )
                )
            }
        }
        return true
    }
}
