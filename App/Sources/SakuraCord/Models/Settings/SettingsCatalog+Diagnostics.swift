import Foundation

nonisolated extension SettingsCatalog {
    static let diagnosticsPage = page(
        .diagnostics, group: .dataSecurity, title: "Diagnostics", image: "stethoscope",
        help: "Inspect app status and export sanitized diagnostic information.",
        keywords: ["logs", "support", "status", "Gateway", "permissions", "export"]
    )

    static let diagnosticsControls: [SettingsControlMetadata] = [
        control(
            .diagnosticsStatusOverview,
            page: .diagnostics,
            section: .diagnosticsStatus,
            label: "Subsystem Status",
            help: "Show current non-identifying account, Gateway, voice, device, notification, cache, update, and permission health.",
            keywords: ["health", "connection", "Gateway", "voice", "permissions"]
        ),
        control(
            .diagnosticsRefresh,
            page: .diagnostics,
            section: .diagnosticsStatus,
            label: "Refresh Status",
            help: "Refresh system permissions, selected-device availability, notification authorization, cache state, and log count without polling.",
            keywords: ["reload", "checking", "current"]
        ),
        control(
            .diagnosticsSupportPreview,
            page: .diagnostics,
            section: .diagnosticsSupport,
            label: "Support Summary",
            help: "Preview fixed non-identifying app, macOS, Mac hardware, feature-health, permission, and diagnostic-mode fields.",
            keywords: ["version", "macOS", "chip", "memory", "storage", "track"]
        ),
        control(
            .diagnosticsSupportCopy,
            page: .diagnostics,
            section: .diagnosticsSupport,
            label: "Copy Support Summary",
            help: "Copy the sanitized support summary as JSON.",
            keywords: ["clipboard", "support", "JSON"]
        ),
        control(
            .diagnosticsSupportExport,
            page: .diagnostics,
            section: .diagnosticsSupport,
            label: "Export Support Summary",
            help: "Export the sanitized support summary as a private JSON file.",
            keywords: ["save", "support", "JSON", "private"]
        ),
        control(
            .diagnosticsOpenFolder,
            page: .diagnostics,
            section: .apiDiagnostics,
            label: "Open Diagnostics Folder",
            help: "Open the managed diagnostics directory when it exists.",
            keywords: ["Finder", "Application Support", "logs"]
        ),
        control(
            .diagnosticConnectionMetrics,
            page: .diagnostics,
            section: .apiDiagnostics,
            label: "Capture connection diagnostics",
            help: "Include connection reuse, protocol, timings, and recovery in API logs to investigate stalls. Excludes IP addresses, credentials, and request content.",
            keywords: ["network", "stall", "timeout", "DNS", "TLS", "HTTP", "connection"]
        ),
        control(
            .diagnosticDetailedPayloads,
            page: .diagnostics,
            section: .apiDiagnostics,
            label: "Capture detailed sanitized payloads",
            help: "Retain protocol payloads in bounded memory and discard sensitive values when saving or exporting.",
            keywords: ["API", "JSON", "redaction"]
        ),
        control(
            .diagnosticDiskCapture,
            page: .diagnostics,
            section: .apiDiagnostics,
            label: "Save diagnostics to disk",
            help: "Write bounded private diagnostic sessions under Application Support.",
            keywords: ["logs", "capture", "files"]
        ),
        control(
            .diagnosticPanicSave,
            page: .diagnostics,
            section: .apiDiagnostics,
            label: "Enable panic save",
            help: "Keep three snapshots when requests, connections, or client content fail to load, including detailed sanitized payloads even when detailed capture is off.",
            keywords: ["automatic", "error", "panic", "save", "logs"]
        ),
        control(
            .diagnosticRetainedEntries,
            page: .diagnostics,
            section: .apiDiagnostics,
            label: "Retained entries",
            help: "Show the number of diagnostic entries in memory.",
            keywords: ["count", "ring buffer"]
        ),
        control(
            .diagnosticExport,
            page: .diagnostics,
            section: .apiDiagnostics,
            label: "Export API Logs",
            help: "Save the retained sanitized JSON Lines diagnostic log.",
            keywords: ["support", "JSONL", "save"]
        ),
        control(
            .diagnosticClear,
            page: .diagnostics,
            section: .apiDiagnostics,
            label: "Clear Logs",
            help: "Clear retained and managed on-disk diagnostics without changing credentials or Discord state.",
            keywords: ["delete", "reset", "memory"]
        ),
    ]
}
