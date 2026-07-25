import AppKit
import DiscordProtocol
import SakuraCordModels
import SwiftUI
import UserNotifications

@main
struct SakuraCordApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel
    private let opensForumPerformanceFixture: Bool

    init() {
        let configuration = AppLaunchConfiguration(arguments: ProcessInfo.processInfo.arguments)
        opensForumPerformanceFixture = configuration.includesForumPerformanceFixture
        let provider: (any ChatProvider)? = configuration.mode == .offlineTesting
            ? MockChatProvider(
                includesLongServerList: configuration.includesLongServerList,
                forumPostCount: configuration.includesForumPerformanceFixture ? 5_000 : nil
            )
            : nil
        _model = State(initialValue: AppModel(
            launchMode: configuration.mode,
            provider: provider,
            notificationService: MacNativeNotificationService()
        ))
    }

    var body: some Scene {
        WindowGroup("SakuraCord", id: "main") {
            RootView(model: model)
                .frame(minWidth: 860, minHeight: 560)
                .task {
                    await model.start()
                    if opensForumPerformanceFixture {
                        model.selectedChannelID = ChannelID(rawValue: 220)
                    }
                }
        }
        .defaultSize(width: 1280, height: 780)
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowBackgroundDragBehavior(.disabled)
        .commands { SakuraCordCommands() }

        Settings {
            SettingsView(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let notificationCenterDelegate = SakuraCordNotificationCenterDelegate()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = notificationCenterDelegate
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class SakuraCordNotificationCenterDelegate: NSObject {}

extension SakuraCordNotificationCenterDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (Int) -> Void
    ) {
        // C++ interoperability currently imports this NS_OPTIONS callback as Int.
        let options: UNNotificationPresentationOptions = [.banner, .list, .sound]
        completionHandler(Int(options.rawValue))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let link = NotificationDeepLink(
            userInfo: response.notification.request.content.userInfo
        ) else { return }
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(
                name: .sakuracordNotificationDeepLink,
                object: link
            )
        }
    }
}
