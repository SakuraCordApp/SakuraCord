import Foundation
import CDave
@testable import SimulatorKit
import Testing

/// Two simulated people form a DAVE group through the voice server's external
/// sender and exchange a frame end to end, as the app and a simulated person do.
struct DaveTests {
    @Test func twoMembersExchangeAnEncryptedFrame() throws {
        let room = Snowflake(1_300_000_000_000_000_000)
        let ada = Snowflake(1_300_000_000_000_000_001), ben = Snowflake(1_300_000_000_000_000_002)
        let sender = try #require(DaveExternalSender(groupID: room))
        let alice = try #require(DaveMember(userID: ada, groupID: room, externalSender: sender.package, recognized: [ben]))
        let bob = try #require(DaveMember(userID: ben, groupID: room, externalSender: sender.package, recognized: [ada]))
        _ = alice.keyPackage()
        let proposals = Dave.combine(proposals: [sender.proposeAdd(epoch: 0, keyPackage: bob.keyPackage())])
        let (commit, welcome) = sender.split(commitWelcome: alice.commit(proposals: proposals))
        #expect(!welcome.isEmpty)
        #expect(alice.apply(commit: commit))
        #expect(bob.join(welcome: welcome))
        alice.useCurrentKey()
        bob.useCurrentKey()

        let opus = Data([0xFC, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])
        let encrypted = try #require(alice.encrypt(opus, ssrc: 1, codec: DAVE_CODEC_OPUS))
        #expect(encrypted != opus)
        #expect(bob.decrypt(encrypted, from: ada, video: false) == opus)
    }
}
