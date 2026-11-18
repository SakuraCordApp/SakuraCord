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
