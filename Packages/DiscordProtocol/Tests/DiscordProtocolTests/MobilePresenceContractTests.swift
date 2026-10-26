import Foundation
import SakuraCordModels
import Testing
@testable import DiscordProtocol

@Test func `mobile platform classification survives member decoding and caching without exposing hidden presence`() throws {
    for (platforms, mobileOnly) in [
        (["mobile": "online"], true),
        (["mobile": "idle"], true),
        (["mobile": "dnd"], true),
        (["mobile": "offline"], false),
        (["mobile": "invisible"], false),
        (["mobile": "unknown"], false),
        (["mobile": "idle", "desktop": "online"], false),
        (["mobile": "dnd", "web": "idle"], false),
        ([:], false),
    ] {
        let clientStatus = try JSONDecoder().decode(
            ClientStatusDTO.self,
            from: JSONEncoder().encode(platforms)
        )
        #expect(clientStatus.isMobileOnly == mobileOnly)
        for status in PresenceStatus.allCases {
            let dto = try JSONValueDecoder().decode(GuildMemberDTO.self, from: .object([
                "user": .object(["id": .string("2"), "username": .string("mobile")]),
                "roles": .array([]),
                "presence": .object([
                    "status": .string(status.rawValue),
                    "client_status": .object(platforms.mapValues { .string($0) }),
                ]),
            ]))
            let member = try dto.domain(currentUserID: nil, currentStatus: .online)
            let cached = try JSONDecoder().decode(Member.self, from: JSONEncoder().encode(member))
            #expect(cached.isMobileOnly == mobileOnly)
            #expect(cached.showsMobileIndicator == (mobileOnly && status.isVisibleOnline))
        }
    }
}
