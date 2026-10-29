import SakuraCordModels
import SwiftUI

/// Withholds a blocked or ignored person's profile until the viewer asks for it.
/// The gate hugs its content. Compact capsules sit close to the popover's edge;
/// larger surfaces keep the roomier modal footer dimensions.
struct SuppressedProfileGate: View {
    let model: AppModel
    let presentation: ProfilePresentationState
    let reason: UserContentSuppression
    var layout: ProfilePresentationLayout = .popover

    // A 14-point capsule radius plus a 6-point inset follows the native
    // popover's 20-point corner, while the expanded card uses 20 + 12 = 32.
    private var footerInset: CGFloat { InterfaceScale.metric(layout == .popover ? 6 : 12) }
    private var buttonHeight: CGFloat { layout == .popover ? 28 : 40 }
    private static var cardCornerRadius: CGFloat { InterfaceScale.metric(32) }

    private var user: User { presentation.member.user }
    private var isPending: Bool { model.friends.pendingUserIDs.contains(user.id) }

    var body: some View {
        switch layout {
        case .popover:
            content
                .frame(width: MemberProfilePopover<EmptyView>.preferredWidth)
        case .inspector:
            // The sidebar is the surface; the gate fills its width and centers.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .expanded:
            content
                .frame(width: MemberProfilePopover<EmptyView>.preferredWidth)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Self.cardCornerRadius, style: .continuous))
                .containerShape(.rect(cornerRadius: Self.cardCornerRadius, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var content: some View {
        VStack(spacing: InterfaceScale.metric(16)) {
            VStack(spacing: InterfaceScale.metric(10)) {
                Image(systemName: reason.systemImage)
                    .font(.interface(.title2).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: InterfaceScale.metric(52), height: InterfaceScale.metric(52))
                    .glassEffect(.regular, in: Circle())
                    .accessibilityHidden(true)
                Text("Show Profile?")
                    .font(.interface(.title3).weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                Text("You \(reason.rawValue) \(model.friendDisplayName(user)). They won’t be notified if you view their profile.")
                    .font(.interface(.callout))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, InterfaceScale.metric(8))
            GlassEffectContainer(spacing: InterfaceScale.metric(8)) {
                // Side by side when both buttons fit; otherwise stacked full width.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: InterfaceScale.metric(8)) {
                        relationshipButton(fillsWidth: false)
                        Spacer(minLength: 0)
                        showProfileButton(fillsWidth: false)
                    }
                    VStack(spacing: InterfaceScale.metric(8)) {
                        showProfileButton(fillsWidth: true)
                        relationshipButton(fillsWidth: true)
                    }
                }
            }
            .disabled(isPending)
        }
        .padding(.top, InterfaceScale.metric(24))
        .padding(footerInset)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Show Profile?")
    }

    private func showProfileButton(fillsWidth: Bool) -> some View {
        ModalGlassButton(symbol: "person.crop.circle", label: "Show Profile", primary: true, fillsWidth: fillsWidth, height: buttonHeight) {
            model.ignoredUsers.revealedProfileRequests.insert(presentation.id)
        }
        .keyboardShortcut(.defaultAction)
    }

    @ViewBuilder
    private func relationshipButton(fillsWidth: Bool) -> some View {
        switch reason {
        case .ignored:
            ModalGlassButton(symbol: "eye", label: "Unignore", isLoading: isPending, fillsWidth: fillsWidth, height: buttonHeight) {
                model.setUserIgnored(user, ignored: false, location: .profileNotice)
            }
        case .blocked:
            ModalGlassButton(symbol: "hand.raised.slash", label: "Unblock", isLoading: isPending, fillsWidth: fillsWidth, height: buttonHeight) {
                model.removeRelationship(with: user.id, as: .unblock)
            }
        }
    }
}
