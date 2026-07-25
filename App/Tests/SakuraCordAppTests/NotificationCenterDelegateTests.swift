@testable import SakuraCord
import Testing
import UserNotifications

@MainActor
@Test func `notification delegate exposes foreground presentation callback to macOS`() {
    let delegate = SakuraCordNotificationCenterDelegate()
    let selector = #selector(
        UNUserNotificationCenterDelegate.userNotificationCenter(
            _:willPresent:withCompletionHandler:
        )
    )

    #expect(delegate.responds(to: selector))
}
