import Testing
@testable import DiscordProtocol

struct AttachmentUploadURLValidationTests {
    @Test func `attachment storage accepts only absolute HTTPS upload URLs`() {
        #expect(
            DiscordRESTProvider.validatedAttachmentUploadURL(
                from: "https://upload.example/object"
            )?.host == "upload.example"
        )
        #expect(
            DiscordRESTProvider.validatedAttachmentUploadURL(
                from: "http://upload.example/object"
            ) == nil
        )
        #expect(
            DiscordRESTProvider.validatedAttachmentUploadURL(
                from: "file:///tmp/object"
            ) == nil
        )
        #expect(
            DiscordRESTProvider.validatedAttachmentUploadURL(
                from: "/relative/object"
            ) == nil
        )
    }
}
