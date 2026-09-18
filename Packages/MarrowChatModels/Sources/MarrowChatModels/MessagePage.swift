import Foundation

public struct MessagePage: Codable, Equatable, Sendable {
    public var messages: [Message]
    public var hasMoreBefore: Bool
    public var hasMoreAfter: Bool
    public var resolvedMembers: [Member]
    public var hasCompleteMemberResolution: Bool

    public init(
        messages: [Message],
        hasMoreBefore: Bool,
        hasMoreAfter: Bool = false,
        resolvedMembers: [Member] = [],
        hasCompleteMemberResolution: Bool = false
    ) {
        self.messages = messages
        self.hasMoreBefore = hasMoreBefore
        self.hasMoreAfter = hasMoreAfter
        self.resolvedMembers = resolvedMembers
        self.hasCompleteMemberResolution = hasCompleteMemberResolution
    }

    enum CodingKeys: String, CodingKey {
        case messages, hasMoreBefore, hasMoreAfter, resolvedMembers
        case hasCompleteMemberResolution
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        messages = try values.decode([Message].self, forKey: .messages)
        hasMoreBefore = try values.decode(Bool.self, forKey: .hasMoreBefore)
        hasMoreAfter = try values.decodeIfPresent(Bool.self, forKey: .hasMoreAfter)
            ?? false
        resolvedMembers = try values.decodeIfPresent(
            [Member].self,
            forKey: .resolvedMembers
        ) ?? []
        hasCompleteMemberResolution = try values.decodeIfPresent(
            Bool.self,
            forKey: .hasCompleteMemberResolution
        ) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(messages, forKey: .messages)
        try values.encode(hasMoreBefore, forKey: .hasMoreBefore)
        try values.encode(hasMoreAfter, forKey: .hasMoreAfter)
        if !resolvedMembers.isEmpty {
            try values.encode(resolvedMembers, forKey: .resolvedMembers)
        }
        if hasCompleteMemberResolution {
            try values.encode(true, forKey: .hasCompleteMemberResolution)
        }
    }
}
