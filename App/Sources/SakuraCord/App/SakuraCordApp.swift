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
    private let runsAuthenticatedNavigationBenchmark: Bool
    private let runsAuthenticatedAccountSwitchBenchmark: Bool
    private let runsHistoryPaginationBenchmark: Bool
    private let runsAuthenticatedGestureScrollBenchmark: Bool
    private let runsLoadingScrollOverlapBenchmark: Bool
    private let preparesTimelineScrollBenchmark: Bool
    private let preparesMemberListScrollBenchmark: Bool
    private let activatesAuthenticatedScrollBenchmark: Bool
    private let performanceMockProvider: MockChatProvider?

    init() {
        AppPerformanceSignposts.beginStartup()
        ComposerPromisedFileStorage.removeAbandonedFilesAtStartup()
        let savesDiagnosticsToDisk = UserDefaults.standard.bool(
            forKey: "saveAPIDiagnosticsToDisk"
        )
        if savesDiagnosticsToDisk {
            do {
                try DiscordAPIDiagnosticStore.shared
                    .setSavesDiagnosticsToDisk(true)
            } catch {
                UserDefaults.standard.set(
                    false,
                    forKey: "saveAPIDiagnosticsToDisk"
                )
            }
        }
        let configuration = AppLaunchConfiguration(arguments: ProcessInfo.processInfo.arguments)
        opensForumPerformanceFixture = configuration.includesForumPerformanceFixture
        opensChatPerformanceFixture = configuration.includesChatPerformanceFixture
        runsChatLiveArrivalStress = configuration.runsChatLiveArrivalStress
        runsAuthenticatedNavigationBenchmark =
            configuration.runsAuthenticatedNavigationBenchmark
        runsAuthenticatedAccountSwitchBenchmark =
            configuration.runsAuthenticatedAccountSwitchBenchmark
        runsHistoryPaginationBenchmark =
            configuration.runsHistoryPaginationBenchmark
        runsAuthenticatedGestureScrollBenchmark =
            configuration.runsAuthenticatedGestureScrollBenchmark
        runsLoadingScrollOverlapBenchmark =
            configuration.runsLoadingScrollOverlapBenchmark
        preparesTimelineScrollBenchmark =
            configuration.mode == .normal
            && configuration.runsChatPerformanceAutoScroll
        preparesMemberListScrollBenchmark =
            configuration.mode == .normal
            && configuration.runsMemberListPerformanceAutoScroll
        activatesAuthenticatedScrollBenchmark =
            configuration.mode == .normal
            && (
                configuration.runsChatPerformanceAutoScroll
                    || configuration.runsMemberListPerformanceAutoScroll
                    || configuration.runsAuthenticatedGestureScrollBenchmark
                    || configuration.runsLoadingScrollOverlapBenchmark
            )
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
        let soundPlayer: any AppSoundPlaying =
            configuration.mode == .offlineTesting
            ? NoopAppSoundPlayer()
            : MacAppSoundPlayer()
        _model = State(initialValue: AppModel(
            launchMode: configuration.mode,
            provider: provider,
            notificationService: notificationService,
            soundPlayer: soundPlayer
        ))
    }

    var body: some Scene {
        // SakuraCord owns one account workspace. A WindowGroup would restore
        // every previously opened main window on the next launch.
        Window("SakuraCord", id: "main") {
            RootView(model: model)
                .frame(minWidth: 860, minHeight: 560)
                .onAppear {
                    AppPerformanceSignposts.reportRootViewAppeared()
                }
                .task {
                    await model.start()
                    if runsAuthenticatedNavigationBenchmark {
                        await model.runAuthenticatedNavigationPerformanceBenchmark()
                    }
                    if runsAuthenticatedAccountSwitchBenchmark {
                        await model.runAuthenticatedAccountSwitchPerformanceBenchmark()
                    }
                    if runsHistoryPaginationBenchmark {
                        await model.runAuthenticatedHistoryPaginationPerformanceBenchmark()
                    }
                    if runsAuthenticatedGestureScrollBenchmark {
                        await model.runAuthenticatedGestureScrollPerformanceBenchmark()
                    }
                    if runsLoadingScrollOverlapBenchmark {
                        await model.runAuthenticatedLoadingScrollOverlapPerformanceBenchmark()
                    }
                    if activatesAuthenticatedScrollBenchmark {
                        // A display-link benchmark is only representative
                        // while AppKit is presenting this window normally.
                        // Background/occluded windows are intentionally
                        // throttled by WindowServer and would report machine
                        // scheduling as SakuraCord frame loss.
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    if preparesTimelineScrollBenchmark {
                        await model.prepareAuthenticatedTimelineScrollPerformanceBenchmark()
                    }
                    if preparesMemberListScrollBenchmark {
                        await model.prepareAuthenticatedMemberListScrollPerformanceBenchmark()
                    }
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
        .defaultLaunchBehavior(.presented)
        .defaultSize(width: 1280, height: 780)
        .windowBackgroundDragBehavior(.disabled)
        .commands {
            SidebarCommands()
            SakuraCordCommands(
                model: model,
                updateController: appDelegate.updateController
            )
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
