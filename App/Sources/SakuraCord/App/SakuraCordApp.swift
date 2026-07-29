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
    private let opensChatPerformanceFixture: Bool
    private let runsChatLiveArrivalStress: Bool
    private let performanceMockProvider: MockChatProvider?

    init() {
        let configuration = AppLaunchConfiguration(arguments: ProcessInfo.processInfo.arguments)
        opensForumPerformanceFixture = configuration.includesForumPerformanceFixture
        opensChatPerformanceFixture = configuration.includesChatPerformanceFixture
        runsChatLiveArrivalStress = configuration.runsChatLiveArrivalStress
        let mockProvider = configuration.mode == .offlineTesting
            ? MockChatProvider(
                includesLongServerList: configuration.includesLongServerList,
                forumPostCount: configuration.includesForumPerformanceFixture ? 5_000 : nil,
                timelineMessageCount: configuration.includesChatPerformanceFixture ? 5_000 : nil,
                timelineIncludesAnimatedMedia:
                    configuration.includesChatMediaPerformanceFixture,
                includesIncomingPrivateCall:
                    configuration.includesIncomingPrivateCallFixture
            )
            : nil
        performanceMockProvider = mockProvider
        let provider: (any ChatProvider)? = mockProvider
        let notificationService: any NativeNotificationService =
            configuration.mode == .offlineTesting
            ? NoopNativeNotificationService()
            : MacNativeNotificationService()
        _model = State(initialValue: AppModel(
            launchMode: configuration.mode,
            provider: provider,
            notificationService: notificationService
        ))
    }

    var body: some Scene {
        WindowGroup("SakuraCord", id: "main") {
            RootView(model: model)
                .frame(minWidth: 860, minHeight: 560)
                .task {
                    await model.start()
                    if opensChatPerformanceFixture {
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    if opensForumPerformanceFixture {
                        model.selectedChannelID = ChannelID(rawValue: 220)
                    } else if opensChatPerformanceFixture {
                        model.selectedChannelID = ChannelID(rawValue: 210)
                    }
                    if runsChatLiveArrivalStress {
                        await NativeTimelinePerformanceBenchmarkGate.shared
                            .waitUntilStarted()
                        guard !Task.isCancelled,
                              let performanceMockProvider
                        else { return }
                        let arguments = ProcessInfo.processInfo.arguments
                        let runsArrivals =
                            !arguments.contains(
                                "--offline-chat-performance-live-mutations-only"
                            )
                        let runsMutations =
                            !arguments.contains(
                                "--offline-chat-performance-live-arrivals-only"
                            )
                        await withTaskGroup(of: Void.self) { group in
                            if runsArrivals {
                                group.addTask {
                                    await performanceMockProvider
                                        .emitTimelineStressMessages(
                                            in: ChannelID(rawValue: 210),
                                            count: 2_400,
                                            burstSize: 4,
                                            burstInterval: .milliseconds(32)
                                        )
                                }
                            }
                            if runsMutations {
                                group.addTask {
                                    await performanceMockProvider
                                        .emitTimelineMutationStress(
                                            in: ChannelID(rawValue: 210),
                                            operationCount: 1_200,
                                            deleteEvery: 5,
                                            lookback: 600,
                                            initialDelay: .milliseconds(500),
                                            operationInterval: .milliseconds(32)
                                        )
                                }
                            }
                        }
                    }
                }
        }
        .defaultSize(width: 1280, height: 780)
        .windowToolbarStyle(.unified(showsTitle: false))
        .windowBackgroundDragBehavior(.disabled)
        .commands {
            SakuraCordCommands(updateController: appDelegate.updateController)
        }

        Settings {
            SettingsView(
                model: model,
                updateController: appDelegate.updateController
            )
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let updateController = AppUpdateController()
    private let notificationCenterDelegate = SakuraCordNotificationCenterDelegate()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = notificationCenterDelegate
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        updateController.start()
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
