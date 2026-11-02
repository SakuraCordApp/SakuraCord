import AppKit
import DiscordProtocol
import SakuraCordModels
import SwiftUI

/// The Direct Messages home. Sections live in the window toolbar; this view
/// owns the list and Add Friend form. Relationship dialogs belong to the workspace.
struct FriendsView: View {
    let model: AppModel

    var body: some View {
        Group {
            if model.isMessageRequestsPresented {
                MessageRequestsView(model: model)
            } else if model.friendsSection == .addFriend {
                ScrollView {
                    AddFriendView(model: model)
                }
                .scrollBounceBehavior(.always, axes: .vertical)
                .scrollEdgeEffectStyle(.soft, for: .top)
            } else {
                FriendsListView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { model.loadRelationshipsIfNeeded(for: model.friendsSection) }
    }
}

extension AppModel {
    func friendDisplayName(_ user: User) -> String {
        friendNickname(for: user.id) ?? user.displayName
    }
}

private struct FriendsListView: View {
    let model: AppModel

    var body: some View {
        let projection = model.friendsProjection
        let query = model.friendsSearchText
        NativeMemberListView(
            sections: projection.displaySections, customEmojiURLsByID: model.customEmojiURLsByID,
            profilePresentation: nil, isProfilePresented: false,
            selectMember: { member in
                guard let row = model.friends.row(for: member.id) else { return }
                if row.relationship.type == .friend {
                    model.openDirectMessage(with: row.user)
                } else if row.relationship.type == .incomingRequest, row.relationship.note != nil,
                          !model.friends.revealedRequestIDs.contains(row.id) {
                    model.friends.revealRequest(row.id)
                } else { model.showFriendProfile(row) }
            },
            dismissProfile: {}, runsPerformanceAutoScroll: false, viewportIdentity: nil,
            presentation: NativeMemberListPresentation(
                roleColorDisplay: .hidden, dimsOfflineMembers: false,
                presenceHiddenUserIDs: projection.pendingIDs, trailingAccessoryWidth: 90
            ),
            rowAccessory: { member in
                AnyView(Group {
                    if let row = model.friends.row(for: member.id) {
                        FriendRowControls(model: model, row: row)
                    }
                })
            },
            rowMenu: { member in
                guard let row = model.friends.row(for: member.id) else { return nil }
                return FriendRowControls(model: model, row: row).nativeMenu()
            },
            rowAccessibilityActions: { member in
                guard let row = model.friends.row(for: member.id) else { return [] }
                return FriendRowControls(model: model, row: row).accessibilityActions()
            },
            contentIdentity: "friends-\(model.friendsSection)-\(query)"
        )
        // Like the message timeline, let rows pass beneath the native toolbar.
        // NSScrollView supplies the initial inset for the overlapping title bar.
        .scrollEdgeEffectStyle(.soft, for: .top)
        .ignoresSafeArea(.container, edges: .top)
        .overlay {
            if projection.count == 0 {
                if !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    emptyState
                }
            }
        }
    }

    // Official stable633029 empty-state copy.
    @ViewBuilder private var emptyState: some View {
        switch model.friendsSection {
        case .pending:
            ContentUnavailableView(
                "No pending friends", systemImage: "person.crop.circle.badge.clock",
                description: Text("There are no pending friend requests. Here’s Wumpus for now.")
            )
        case .online, .all, .addFriend:
            ContentUnavailableView {
                Label("No one’s around", systemImage: "person.2")
            } description: {
                Text("Wumpus is waiting on friends. You don’t have to though!")
            } actions: {
                Button("Add Friend") { model.selectFriendsSection(.addFriend) }
                    .buttonStyle(.glassProminent)
                    .tint(SakuraCordAccentColor.color)
            }
        }
    }
}

private struct FriendRowControls: View {
    let model: AppModel
    let row: FriendRow
    private var isPending: Bool { model.friends.pendingUserIDs.contains(row.id) }

    var body: some View {
        HStack(spacing: InterfaceScale.metric(6)) {
            if isPending { ProgressView().controlSize(.small) }
            actions.disabled(isPending)
        }
    }

    @ViewBuilder private var actions: some View {
        GlassEffectContainer(spacing: InterfaceScale.metric(6)) {
            HStack(spacing: InterfaceScale.metric(6)) {
                switch row.relationship.type {
                case .incomingRequest:
                    rowButton("Accept", systemImage: "checkmark", tint: .green) {
                        model.acceptFriendRequest(from: row.user)
                    }
                    rowButton("Decline Request", systemImage: "xmark") {
                        model.removeRelationship(with: row.user.id, as: .declineIncomingRequest)
                    }
                case .outgoingRequest:
                    rowButton("Cancel", systemImage: "xmark") {
                        model.removeRelationship(with: row.user.id, as: .cancelOutgoingRequest)
                    }
                default:
                    rowButton("Message", systemImage: "bubble.left.fill") { model.openDirectMessage(with: row.user) }
                    UserContextMenuButton { nativeMenu() }
                        .frame(width: InterfaceScale.metric(32), height: InterfaceScale.metric(32))
                        .glassEffect(.regular.interactive(), in: Circle())
                        .help("More")
                }
            }
        }
    }

    private func rowButton(_ title: String, systemImage: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .font(.interface(.callout).weight(.semibold))
                .foregroundStyle(tint ?? .primary)
                .frame(width: InterfaceScale.metric(32), height: InterfaceScale.metric(32))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help(title)
    }

    func accessibilityActions() -> [NSAccessibilityCustomAction] {
        UserContextMenu.accessibilityActions(for: row.user, context: .init(), model: model)
    }

    func nativeMenu() -> NSMenu? {
        UserContextMenu.make(for: row.user, context: .init(), model: model)
    }

}

private struct AddFriendView: View {
    private enum Field { case username, note }

    let model: AppModel
    @FocusState private var focusedField: Field?

    /// Concentric with the capsule Send button: its 17 pt radius plus the 6 pt inset around it.
    private var areaShape: ConcentricRectangle {
        ConcentricRectangle(cornerRadius: InterfaceScale.metric(23), style: .continuous)
    }

    var body: some View {
        @Bindable var friends = model.friends
        VStack(alignment: .leading, spacing: InterfaceScale.metric(10)) {
            Text("Add Friend")
                .font(.interface(.title2).weight(.semibold))
            Text("You can add friends with their Discord usernames.")

            VStack(spacing: 0) {
                usernameRow(friends: friends)
                Divider()
                    .padding(.horizontal, InterfaceScale.metric(14))
                noteField(friends: friends)
            }
            .glassEffect(.regular, in: areaShape)
            .overlay {
                areaShape
                    .stroke(borderColor(friends), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .padding(.top, InterfaceScale.metric(6))
            .onExitCommand { focusedField = nil }

            Text("What you write here will also show up in your DM if you become friends.")
                .font(.interface(.callout))
                .foregroundStyle(.secondary)

            if let error = friends.addFriendError {
                Text(error)
                    .foregroundStyle(Color(hex: 0xF23F43))
                    .accessibilityAddTraits(.isStaticText)
            } else if let username = friends.addFriendSuccess {
                Text("Success! Your friend request to **\(username)** was sent.")
                    .foregroundStyle(Color(hex: 0x23A55A))
            }
            Spacer(minLength: 0)
        }
        .font(.interface(.body))
        .padding(InterfaceScale.metric(24))
        .frame(maxWidth: InterfaceScale.metric(720), alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { ProfileEditorFocusDismissal() }
        .onAppear { focusedField = .username }
        .onChange(of: friends.addFriendFocusRequest) { _, _ in focusedField = .username }
    }

    private func usernameRow(friends: FriendsState) -> some View {
        @Bindable var friends = friends
        let hasUsername = !friends.addFriendText.isEmpty
        let canSend = hasUsername && !friends.isSendingRequest
            && friends.addFriendNote.utf16.count <= FriendRequestNote.maximumLength
        return HStack(spacing: InterfaceScale.metric(8)) {
            // A single-line plain field draws its placeholder a point away from where its
            // field editor does, so the native placeholder jumps when the field gains focus.
            TextField(text: $friends.addFriendText, prompt: Text(verbatim: "")) { Text("Enter a username") }
                .overlay(alignment: .leading) {
                    Text("Enter a username")
                        .foregroundStyle(Color(nsColor: .placeholderTextColor))
                        .opacity(friends.addFriendText.isEmpty ? 1 : 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .textFieldStyle(.plain)
                .tint(SakuraCordAccentColor.color)
                .focused($focusedField, equals: .username)
                .onSubmit { if canSend { model.sendFriendRequest() } }
                .onChange(of: friends.addFriendText) { _, value in
                    if value.count > FriendsListPolicy.usernameMaximumLength {
                        friends.addFriendText = String(value.prefix(FriendsListPolicy.usernameMaximumLength))
                    }
                    friends.addFriendError = nil
                    if !value.isEmpty { friends.addFriendSuccess = nil }
                }
                .accessibilityLabel("Username")
                .disabled(friends.isSendingRequest)
                .padding(.leading, InterfaceScale.metric(14))

            Button {
                model.sendFriendRequest()
            } label: {
                Text("Send Friend Request")
                    .font(.interface(.callout).weight(.semibold))
                    .opacity(friends.isSendingRequest ? 0 : 1)
                    .overlay { if friends.isSendingRequest { InteractionLoadingDotsView(tone: .onFill) } }
                    .padding(.horizontal, InterfaceScale.metric(14))
                    .frame(height: InterfaceScale.metric(34))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            // The accent fill stays while sending so the loading dots remain visible;
            // white text on untinted glass would vanish in light mode.
            .foregroundStyle(hasUsername ? Color.white : Color.secondary)
            .glassEffect(
                hasUsername ? .regular.tint(SakuraCordAccentColor.color).interactive() : .regular,
                in: Capsule()
            )
            .disabled(!canSend)
        }
        .padding(InterfaceScale.metric(6))
        .frame(minHeight: InterfaceScale.metric(46))
        // Behind the field, so clicks inside its text stay with the native editor.
        .background { Color.clear.contentShape(Rectangle()).onTapGesture { focusFromPadding(.username) } }
    }

    private func noteField(friends: FriendsState) -> some View {
        @Bindable var friends = friends
        let remaining = FriendRequestNote.maximumLength - friends.addFriendNote.utf16.count
        return VStack(alignment: .trailing, spacing: InterfaceScale.metric(4)) {
            TextField("Personalize your request (Optional)", text: $friends.addFriendNote, axis: .vertical)
                .lineLimit(2 ... 3)
                .textFieldStyle(.plain)
                .tint(SakuraCordAccentColor.color)
                .focused($focusedField, equals: .note)
                .disabled(friends.isSendingRequest)
            Text("\(remaining)")
                .font(.interface(.callout))
                .monospacedDigit()
                .foregroundStyle(remaining < 0 ? Color.red : .secondary)
        }
        .padding(.horizontal, InterfaceScale.metric(14))
        .padding(.vertical, InterfaceScale.metric(12))
        // Behind the field, so clicks inside its text stay with the native editor.
        .background { Color.clear.contentShape(Rectangle()).onTapGesture { focusFromPadding(.note) } }
    }

    /// A click in a field's padding focuses that field. ProfileEditorFocusDismissal
    /// blurs the current field after any click outside it, so focus moves on the
    /// next turn of the run loop, after that blur. Gaining focus selects the whole
    /// field, so the caret then goes to the end, as a click beside the text would.
    private func focusFromPadding(_ field: Field) {
        DispatchQueue.main.async {
            focusedField = field
            DispatchQueue.main.async {
                guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            }
        }
    }

    private func borderColor(_ friends: FriendsState) -> Color {
        if friends.addFriendError != nil { return Color(hex: 0xF23F43) }
        if friends.addFriendSuccess != nil { return Color(hex: 0x23A55A) }
        return focusedField == nil ? .clear : SakuraCordAccentColor.color.opacity(0.7)
    }
}
