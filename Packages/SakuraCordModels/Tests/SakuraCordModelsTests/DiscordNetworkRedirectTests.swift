import Foundation
@testable import SakuraCordModels
import Testing

@Test func `a bundle recorded as a simulator launch never relaunches on the real account`() {
    let pathLaunch = ["/dist/SakuraCord Debug.app/Contents/MacOS/SakuraCord Debug"]
    #expect(DiscordNetworkRedirect.basePort(arguments: pathLaunch, environment: [:], recordedPort: 47200) == 47200)
    #expect(DiscordNetworkRedirect.basePort(
        arguments: pathLaunch + ["--discord-simulator", "47300"], environment: [:], recordedPort: 47200
    ) == 47300)
    #expect(DiscordNetworkRedirect.basePort(arguments: pathLaunch, environment: [:], recordedPort: nil) == nil)
}

@Test func `an unreadable simulator launch record still selects the simulator`() throws {
    let bundle = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: bundle) }
    func record(_ value: String) {
        _ = setxattr(bundle.path, DiscordNetworkRedirect.recordedPortAttribute, value, value.utf8.count, 0, 0)
    }
    #expect(DiscordNetworkRedirect.recordedPort(of: bundle) == nil)
    record("47200")
    #expect(DiscordNetworkRedirect.recordedPort(of: bundle) == 47200)
    record("not a port")
    #expect(DiscordNetworkRedirect.recordedPort(of: bundle) == 47100)
}
