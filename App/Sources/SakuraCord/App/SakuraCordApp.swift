import AppKit
import DiscordProtocol
import SakuraCordModels
import SwiftUI

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
            provider: provider
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
