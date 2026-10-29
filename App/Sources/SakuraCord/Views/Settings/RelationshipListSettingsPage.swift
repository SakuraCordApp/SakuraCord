import SakuraCordModels
import SwiftUI

/// The relationship lists Privacy settings manages, as in Discord's
/// Ignore & Block settings.
enum ManagedRelationshipList: Hashable {
    case blocked
    case ignored

    var title: LocalizedStringResource {
        switch self {
        case .blocked: LocalizedStringResource("Blocked Accounts", bundle: #bundle)
        case .ignored: LocalizedStringResource("Ignored Accounts", bundle: #bundle)
        }
    }

    var systemImage: String {
        switch self {
        case .blocked: "nosign"
        case .ignored: "eye.slash.circle"
        }
    }

    var emptyTitle: LocalizedStringResource {
        switch self {
        case .blocked: LocalizedStringResource("No Blocked Accounts", bundle: #bundle)
        case .ignored: LocalizedStringResource("No Ignored Accounts", bundle: #bundle)
        }
    }

    var actionTitle: LocalizedStringResource {
        switch self {
        case .blocked: LocalizedStringResource("Unblock", bundle: #bundle)
        case .ignored: LocalizedStringResource("Unignore", bundle: #bundle)
        }
    }

    func contains(_ relationship: Relationship) -> Bool {
        switch self {
        case .blocked: relationship.type == .blocked
        case .ignored: relationship.isIgnored
        }
    }

    @MainActor
    func remove(_ userID: UserID, in model: AppModel) {
        switch self {
        case .blocked: model.removeRelationship(with: userID, as: .unblock)
        case .ignored: model.setUserIgnored(userID, ignored: false, location: .settings)
        }
    }
}

struct RelationshipListSettingsPage: View {
    let model: AppModel
    let list: ManagedRelationshipList

    @State private var searchText = ""

    private var relationships: [Relationship] {
        model.relationships.filter(list.contains).sorted {
            name(for: $0).localizedStandardCompare(name(for: $1)) == .orderedAscending
        }
    }

    var body: some View {
        let relationships = relationships
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = query.isEmpty ? relationships : relationships.filter { matches($0, query: query) }
        SettingsForm {
            Section {
                if relationships.isEmpty {
                    emptyState(ContentUnavailableView {
                        Label { Text(list.emptyTitle) } icon: { Image(systemName: list.systemImage) }
                    })
                } else if visible.isEmpty {
                    emptyState(ContentUnavailableView.search(text: query))
                } else {
                    ForEach(visible) { relationship in
                        row(relationship)
                    }
                }
            } footer: {
                if let error = model.friends.actionError {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(Text(list.title))
        .searchable(text: $searchText, prompt: Text("Search \(Text(list.title))", bundle: #bundle))
    }

    private func row(_ relationship: Relationship) -> some View {
        HStack(spacing: InterfaceScale.metric(10)) {
            AvatarView(name: name(for: relationship), url: relationship.user?.avatarURL, size: InterfaceScale.metric(32))
            VStack(alignment: .leading) {
                Text(name(for: relationship))
                if let user = relationship.user {
                    Text(user.tag).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                list.remove(relationship.id, in: model)
            } label: {
                Text(list.actionTitle)
            }
            .disabled(model.friends.pendingUserIDs.contains(relationship.id))
        }
    }

    private func emptyState(_ view: some View) -> some View {
        view
            .frame(maxWidth: .infinity, minHeight: InterfaceScale.metric(260))
            .listRowInsets(EdgeInsets())
    }

    private func name(for relationship: Relationship) -> String {
        relationship.user.map(model.friendDisplayName) ?? relationship.id.description
    }

    private func matches(_ relationship: Relationship, query: String) -> Bool {
        name(for: relationship).localizedStandardContains(query)
            || relationship.user?.tag.localizedStandardContains(query) == true
    }
}
