@testable import SakuraCordModels
import Testing

@Test func `attachment limits follow Discord account premium tiers`() {
    #expect(DiscordAttachmentUploadPolicy.maximumFileSize(premiumType: 0) == 20 * 1_024 * 1_024)
    #expect(DiscordAttachmentUploadPolicy.maximumFileSize(premiumType: 1) == 50 * 1_024 * 1_024)
    #expect(DiscordAttachmentUploadPolicy.maximumFileSize(premiumType: 2) == 500 * 1_024 * 1_024)
    #expect(DiscordAttachmentUploadPolicy.maximumFileSize(premiumType: 3) == 50 * 1_024 * 1_024)
    #expect(DiscordAttachmentUploadPolicy.maximumFileSize(premiumType: 999) == 20 * 1_024 * 1_024)
}

@Test func `attachment limit includes the boundary and rejects the next byte`() {
    for premiumType in [0, 1, 2, 3] {
        let limit = DiscordAttachmentUploadPolicy.maximumFileSize(premiumType: premiumType)
        #expect(DiscordAttachmentUploadPolicy.allows(fileSize: limit, premiumType: premiumType))
        #expect(!DiscordAttachmentUploadPolicy.allows(fileSize: limit + 1, premiumType: premiumType))
    }
}
