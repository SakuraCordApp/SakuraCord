import SakuraCordModels
import SwiftUI

struct ProfileEditorExpandedPreview: View {
    let model: AppModel
    let editor: ProfileEditorState
    let profile: UserProfile
    let open: (ProfileEditorPicker) -> Void

    private var frameInsets: EdgeInsets {
        guard !model.cosmeticPolicy.disables(.frame, for: profile.id), let frame = profile.frame else { return EdgeInsets() }
        let scale = MemberProfilePopover<EmptyView>.preferredWidth / max(1, frame.innerWidth)
        return EdgeInsets(top: ceil(max(0, frame.overflowTop) * scale), leading: 0,
                          bottom: ceil(max(0, frame.overflowBottom) * scale), trailing: 0)
    }

    var body: some View {
        ProfileExpandedSurface(profile: profile, allowsTheme: editor.isNitro, profileContent: {
            MemberProfilePopover(member: Member(user: profile.user, roleName: "", status: model.currentStatus,
                                                joinedAt: editor.scope.guildID.flatMap { model.profileMember(profile.id, in: $0)?.joinedAt }),
                                 isCurrentUser: true, profile: profile,
                                 isLoading: false, errorMessage: nil, layout: .expanded, maximumPopoverHeight: InterfaceScale.metric(720), showsRoles: false,
                                 guild: editor.scope.guildID.flatMap { model.serverRailGuildsByID[$0] },
                                 footer: EmptyView(), editor: editor, openEditorPicker: open)
                .disabled(editor.isSaving || editor.requiresReload)
        }, widgets: {
            ProfileWidgetsBoard(editor: editor)
                .id(editor.draftGeneration)
                .settingsControlAnchor(.profileWidgets)
        })
        .background(Color(nsColor: .windowBackgroundColor), in: ConcentricRectangle(cornerRadius: InterfaceScale.metric(16), style: .continuous))
        .clipShape(ConcentricRectangle(cornerRadius: InterfaceScale.metric(16), style: .continuous))
        .overlay { ConcentricRectangle(cornerRadius: InterfaceScale.metric(16), style: .continuous).stroke(.separator, lineWidth: 1) }
        .backgroundPreferenceValue(ProfileFrameAnchorKey.self) { anchor in
            ProfileFrameDecoration(anchor: anchor, order: "back")
        }
        .overlayPreferenceValue(ProfileFrameAnchorKey.self) { anchor in
            ProfileFrameDecoration(anchor: anchor, order: "front")
        }
        .padding(frameInsets)
    }
}
