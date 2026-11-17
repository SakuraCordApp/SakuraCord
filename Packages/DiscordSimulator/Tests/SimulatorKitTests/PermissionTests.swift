import Foundation
@testable import SimulatorKit
import Testing

/// Timed-out members kept every permission, so they could still post, react and join voice.
struct PermissionTests {
    @Test func timeoutLeavesOnlyViewingUntilItEnds() {
        let now = Date(timeIntervalSince1970: 1_794_778_200)
        let (guildID, ownerID, memberID, adminID) = (Snowflake(1), Snowflake(2), Snowflake(3), Snowflake(4))
        var guild = Guild(id: guildID, name: "Porch", ownerID: ownerID)
        let admins = Role(id: Snowflake(5), name: "Admins", permissions: [.administrator])
        guild.roles = [WorldBuilder.everyoneRole(guildID: guildID), admins]
        var member = Member(userID: memberID, joinedAt: now)
        member.communicationDisabledUntil = now.addingTimeInterval(60)
        guild.members[memberID] = member
        var admin = Member(userID: adminID, joinedAt: now)
        admin.roles = [admins.id]
        admin.communicationDisabledUntil = now.addingTimeInterval(60)
        guild.members[adminID] = admin
        let channel = Channel(id: Snowflake(6), type: .text, guildID: guildID, name: "general")

        #expect(guild.permissions(of: memberID, in: channel, at: now) == [.viewChannel, .readMessageHistory])
        #expect(guild.permissions(of: memberID, in: channel, at: now.addingTimeInterval(61)).contains(.sendMessages))
        #expect(guild.permissions(of: adminID, in: channel, at: now) == .all)
    }
}
