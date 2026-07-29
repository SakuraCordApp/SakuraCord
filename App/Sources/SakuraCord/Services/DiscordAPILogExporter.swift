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

        let response = await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response)
            }
        }
        guard response == .OK, let url = panel.url else { return nil }
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func fileTimestamp(now: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter.string(from: now)
    }
}
