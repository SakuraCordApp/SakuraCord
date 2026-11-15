import SakuraCordModels
import SwiftUI

struct MessageProfilePopoverContent: View {
    let model: AppModel
    let userID: UserID
    let requestID: UUID

    var body: some View {
        Group {
            if let presentation = model.liveProfilePresentation(for: .contextual),
               presentation.member.id == userID,
               presentation.requestID == requestID
            {
                ProfilePresentationContent(presentation: presentation, openProfile: model.expandProfile, userMenu: {
                    UserContextMenu.make(for: presentation.member.user, context: .init(guildID: presentation.guildID), model: model)
                }, sendMessage: model.sendProfileMessage)
                    .environment(\.profileCosmeticPolicy, model.cosmeticPolicy)
                    .environment(\.serverTagCardModel, model)
            } else {
                Color.clear.frame(width: InterfaceScale.metric(330), height: InterfaceScale.metric(250))
            }
        }
        .onDisappear {
            model.dismissContextualProfile(requestID: requestID)
        }
    }
}
