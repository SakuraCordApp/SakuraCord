import CLibdave
import Logging

let logger = Logger(label: "net.robort.davekit")

extension Logger.Level {
    init?(from: DAVELoggingSeverity) {
        switch from {
        case .LOGGING_SEVERITY_NONE:
            return nil
        case .LOGGING_SEVERITY_VERBOSE:
            self = .debug
        case .LOGGING_SEVERITY_INFO:
            self = .info
        case .LOGGING_SEVERITY_WARNING:
            self = .warning
        case .LOGGING_SEVERITY_ERROR:
            self = .error
        }
    }
}

/// Callback function registered with libdave via `daveSetLogSinkCallback`.
/// This function translates libdave log messages into Swift Logging framework log messages.
func logSyncCallback(
    severity: DAVELoggingSeverity,
    file: UnsafePointer<CChar>?,
    line: Int32,
    message: UnsafePointer<CChar>?
) {
    guard let message else { return }
    let logMessage = String(cString: message)
    if let level = Logger.Level(from: severity) {
        logger.log(level: level, "\(logMessage)", metadata: [
            "file": .string(file.map(String.init(cString:)) ?? "unknown"),
            "line": .stringConvertible(line)
        ])
    }
}
