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
    private let opensPinsPerformanceFixture: Bool
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
        SharedMediaDataLoader.removeAbandonedDownloadsAtStartup()
        DiagnosticsPreferences.restore()
        let configuration = AppLaunchConfiguration(arguments: ProcessInfo.processInfo.arguments)
        opensForumPerformanceFixture = configuration.includesForumPerformanceFixture
        opensChatPerformanceFixture = configuration.includesChatPerformanceFixture
        opensPinsPerformanceFixture = configuration.includesPinsPerformanceFixture
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
                pinnedMessageCount: configuration.includesPinsPerformanceFixture ? 5_000 : nil,
                timelineIncludesAnimatedMedia:
                    configuration.includesChatMediaPerformanceFixture,
                includesIncomingPrivateCall:
                    configuration.includesIncomingPrivateCallFixture
            )
            : nil
        performanceMockProvider = mockProvider
        let provider: (any ChatProvider)? = mockProvider
        let notificationService = MacNativeNotificationService(
            deliversNotifications: configuration.mode != .offlineTesting
        )
        let soundPlayer: any AppSoundPlaying =
            configuration.mode == .offlineTesting
            ? NoopAppSoundPlayer()
            : MacAppSoundPlayer()
        let appModel = AppModel(
            launchMode: configuration.mode,
            awaitsOfflineSignIn: configuration.includesSignInFixture,
            hasSavedAccountsAtLaunch: configuration.mode == .normal
                && UserDefaultsSavedAccountStore.shared.hasSavedAccounts,
            provider: provider,
            notificationService: notificationService,
            soundPlayer: soundPlayer
        )
        appModel.showInspector = GeneralWindowRestorationStore.shared.memberListIsVisible
        AppAppearanceController.shared.apply(
            appModel.appearanceSettings.colorScheme
        )
        SakuraCordRuntimeModelHolder.shared.model = appModel
        _model = State(initialValue: appModel)
    }

    var body: some Scene {
        // SakuraCord owns one account workspace. A WindowGroup would restore
        // every previously opened main window on the next launch.
        Window("SakuraCord", id: "main") {
            RootView(model: model)
                .modifier(TranslationTaskHost(coordinator: model.translation.coordinator))
                .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
                    model.resetAllTranslations()
                }
                .focusedSceneValue(\.shortcutCommandContext, .workspace(model))
                .windowModalInputScope()
                .frame(minWidth: 860, minHeight: 560)
                .onAppear {
                    appDelegate.model = model
                    AppPerformanceSignposts.reportRootViewAppeared()
                }
                .task {
                    await appDelegate.startSession(for: model)
                    await model.applyConfiguredLocalStorageLimit()
#if DEBUG
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
#endif
                    if opensChatPerformanceFixture {
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    if opensForumPerformanceFixture {
                        model.selectedChannelID = ChannelID(rawValue: 220)
                    } else if opensChatPerformanceFixture {
                        model.selectedChannelID = ChannelID(rawValue: 210)
                    }
                    if opensPinsPerformanceFixture {
                        await model.channelLoadTask?.value
                        model.presentPinnedMessages(channelID: ChannelID(rawValue: 210))
                        await model.pinnedMessages.loadTask?.value
                        await model.preparePinnedMessagesPerformanceBenchmark()
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
            SakuraCordCommands(
                updateController: appDelegate.updateController
            )
        }

        Settings {
            SettingsView(
                model: model,
                updateController: appDelegate.updateController
            )
            .windowModalInputScope()
        }
        .defaultSize(width: 1060, height: 760)
        .windowResizability(.contentSize)
        .windowManagerRole(.associated)
        .restorationBehavior(.disabled)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let updateController: AppUpdateController
    weak var model: AppModel?
    private let notificationCenterDelegate = SakuraCordNotificationCenterDelegate()
    private var terminationPromptIsPresented = false
    private var sessionStartTask: Task<Void, Never>?

    override init() {
        let configuration = AppLaunchConfiguration(arguments: ProcessInfo.processInfo.arguments)
        if configuration.mode == .normal {
            SakuraCordOnboardingStore.registerInstallation()
        }
        updateController = AppUpdateController()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = notificationCenterDelegate
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        updateController.start()
        if let model = SakuraCordRuntimeModelHolder.shared.model {
            self.model = model
            model.reportApplicationActive(NSApp.isActive)
            Task {
                await startSession(for: model)
                await DiagnosticsSupportSummary.refreshLogSnapshot(
                    model: model, updateController: updateController
                )
            }
        }
    }

    func startSession(for model: AppModel) async {
        self.model = model
        if sessionStartTask == nil {
            sessionStartTask = Task { await model.start() }
        }
        await sessionStartTask?.value
        model.reportApplicationActive(NSApp.isActive)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model?.reportApplicationActive(true)
    }

    func applicationDidResignActive(_ notification: Notification) {
        model?.reportApplicationActive(false)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let confirmsActiveWork = SettingsPreferenceStore.shared.value(
            for: .confirmQuitActiveWork
        ) != .bool(false)
        let activities = model?.generalQuitActivities ?? []
        guard GeneralQuitConfirmationPolicy.shouldConfirm(
            isEnabled: confirmsActiveWork,
            activities: activities
        ) else { return .terminateNow }
        guard !terminationPromptIsPresented else { return .terminateLater }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Quit SakuraCord?"
        alert.informativeText = quitConfirmationMessage(for: activities)
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")

        if let window = sender.keyWindow ?? sender.mainWindow {
            terminationPromptIsPresented = true
            alert.beginSheetModal(for: window) { [weak self] response in
                self?.terminationPromptIsPresented = false
                sender.reply(toApplicationShouldTerminate: response == .alertFirstButtonReturn)
            }
            return .terminateLater
        }
        return alert.runModal() == .alertFirstButtonReturn
            ? .terminateNow
            : .terminateCancel
    }

    private func quitConfirmationMessage(
        for activities: [GeneralQuitActivity]
    ) -> String {
        let descriptions = activities.map(\.title)
        let joined = ListFormatter.localizedString(byJoining: descriptions)
        return "SakuraCord is handling \(joined). Quitting will stop this activity immediately."
    }
}

@MainActor
private final class SakuraCordRuntimeModelHolder {
    static let shared = SakuraCordRuntimeModelHolder()
    weak var model: AppModel?
}

final class SakuraCordNotificationCenterDelegate: NSObject {}

extension SakuraCordNotificationCenterDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (Int) -> Void
    ) {
        // C++ interoperability currently imports this NS_OPTIONS callback as Int.
        // A background notification may finish preparing after the app becomes active.
        let options: UNNotificationPresentationOptions = [.sound]
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
