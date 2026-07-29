@testable import SakuraCord
import AppKit
import Testing

@MainActor
struct DiscordAPILogExporterTests {
    @Test func `API log exporter attaches its save panel to the active settings window`() async {
        let panel = NSSavePanel()
        let window = NSWindow()
        var usedSheet = false
        var usedApplicationModal = false

        let response = await DiscordAPILogExporter.present(
            panel,
            attachedTo: window,
            beginSheet: { receivedPanel, receivedWindow, completion in
                usedSheet = receivedPanel === panel && receivedWindow === window
                completion(.cancel)
            },
            beginApplicationModal: { _, completion in
                usedApplicationModal = true
                completion(.cancel)
            }
        )

        #expect(response == .cancel)
        #expect(usedSheet)
        #expect(!usedApplicationModal)
    }

    @Test func `API log exporter falls back when no presentation window exists`() async {
        let panel = NSSavePanel()
        var usedSheet = false
        var usedApplicationModal = false

        let response = await DiscordAPILogExporter.present(
            panel,
            attachedTo: nil,
            beginSheet: { _, _, completion in
                usedSheet = true
                completion(.cancel)
            },
            beginApplicationModal: { receivedPanel, completion in
                usedApplicationModal = receivedPanel === panel
                completion(.cancel)
            }
        )

        #expect(response == .cancel)
        #expect(!usedSheet)
        #expect(usedApplicationModal)
    }
}
