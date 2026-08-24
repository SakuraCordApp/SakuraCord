import AppKit
import DiscordProtocol
import Foundation
import UniformTypeIdentifiers

@MainActor
enum DiscordAPILogExporter {
    static func export() async throws -> URL? {
        let data = try DiscordAPIDiagnosticStore.shared.exportData()
        let panel = NSSavePanel()
        panel.title = "Export Discord API Logs"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let jsonLines = UTType(filenameExtension: "jsonl") {
            panel.allowedContentTypes = [jsonLines]
        }
        panel.nameFieldStringValue =
            "SakuraCord Discord API Logs \(fileTimestamp()).jsonl"

        let response = await present(
            panel,
            attachedTo: NSApp.keyWindow ?? NSApp.mainWindow
        )
        guard response == .OK, let url = panel.url else { return nil }
        try await write(data, to: url)
        return url
    }

    static func write(
        _ data: Data,
        to url: URL,
        stagingRootURL: URL? = nil
    ) async throws {
        try await ExactDestinationFileWriter.write(
            data,
            to: url,
            stagingRootURL: stagingRootURL,
            posixPermissions: 0o600
        )
    }

    static func present(
        _ panel: NSSavePanel,
        attachedTo presentingWindow: NSWindow?
    ) async -> NSApplication.ModalResponse {
        await present(
            panel,
            attachedTo: presentingWindow,
            beginSheet: { panel, window, completion in
            panel.beginSheetModal(for: window, completionHandler: completion)
            },
            beginApplicationModal: { panel, completion in
                panel.begin(completionHandler: completion)
            }
        )
    }

    static func present<Panel: AnyObject, Window: AnyObject>(
        _ panel: Panel,
        attachedTo presentingWindow: Window?,
        beginSheet: @escaping (
            Panel,
            Window,
            @escaping (NSApplication.ModalResponse) -> Void
        ) -> Void,
        beginApplicationModal: @escaping (
            Panel,
            @escaping (NSApplication.ModalResponse) -> Void
        ) -> Void
    ) async -> NSApplication.ModalResponse {
        let response = await withCheckedContinuation { continuation in
            let completion: (NSApplication.ModalResponse) -> Void = { [panel] response in
                _ = panel
                continuation.resume(returning: response)
            }
            if let presentingWindow {
                beginSheet(panel, presentingWindow, completion)
            } else {
                beginApplicationModal(panel, completion)
            }
        }
        return response
    }

    private static func fileTimestamp(now: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter.string(from: now)
    }
}
