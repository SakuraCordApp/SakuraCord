@testable import DiscordProtocol
import Testing

@Test func `worktree builds isolate keychain credentials from the primary app`() {
    #expect(
        CredentialServiceName.resolve(bundleIdentifier: "dev.sakuracord.SakuraCord")
            == CredentialServiceName.primary
    )
    #expect(
        CredentialServiceName.resolve(bundleIdentifier: nil)
            == CredentialServiceName.primary
    )

    let worktreeIdentifier = "dev.sakuracord.SakuraCord.worktree.wauthenticated-audi"
    #expect(
        CredentialServiceName.resolve(bundleIdentifier: worktreeIdentifier)
            == "\(CredentialServiceName.primary).\(worktreeIdentifier)"
    )
}
