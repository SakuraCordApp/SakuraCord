import Foundation

/// The Edit Group dialog's changes to a group DM. Unchanged fields are omitted
/// from the request.
public struct GroupDirectMessageChanges: Hashable, Sendable {
    /// Discord's group-name limit, counted in UTF-16 units like its input.
    public static let maximumNameLength = 100

    /// The new name; `.clear` restores the member-list title.
    public var name: ProfileChange<String>
    /// A cropped icon upload; `.clear` removes the icon.
    public var icon: ProfileChange<ProfileImageUpload>

    public init(name: ProfileChange<String> = .unchanged, icon: ProfileChange<ProfileImageUpload> = .unchanged) {
        self.name = name
        self.icon = icon
    }

    public var hasChanges: Bool { name.isChanged || icon.isChanged }
}
