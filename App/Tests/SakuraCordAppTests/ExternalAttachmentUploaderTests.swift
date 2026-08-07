@testable import SakuraCord
import Foundation
import Testing

@Test func `external attachment uploader defaults to a cookie free ephemeral session`() {
    let uploader = CatboxAttachmentUploader()
    let configuration = uploader.session.configuration

    #expect(configuration.identifier == nil)
    #expect(configuration.httpCookieStorage == nil)
    #expect(!configuration.httpShouldSetCookies)
}

@Test func `external attachment uploader preserves injected sessions`() {
    let session = URLSession(configuration: .ephemeral)

    #expect(CatboxAttachmentUploader(session: session).session === session)
}
