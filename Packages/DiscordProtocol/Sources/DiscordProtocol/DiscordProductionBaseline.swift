import Foundation

/// Sanitized protocol constants observed from Discord's production app bootstrap.
/// These values are compatibility fixtures, not a promise of policy compliance.
public struct DiscordProductionBaseline: Codable, Equatable, Sendable {
    public var observedAt: Date
    public var webBuildNumber: Int
    public var apiVersion: Int
    public var desktopVersion: String
    public var electronVersion: String
    public var chromiumVersion: String
    public var nativeBuildNumber: Int
    public var apexAppSurface: Int
    public var webGatewayEncoding: String
    public var webGatewayCompression: String
    public var desktopGatewayEncoding: String
    public var desktopGatewayCompression: String
    public var defaultCapabilities: Int
    public var privateChannelObfuscationCapabilities: Int
    public var qosHeartbeatVersion: Int

    public static let august2026 = DiscordProductionBaseline(
        observedAt: Date(timeIntervalSince1970: 1_785_773_429),
        webBuildNumber: 587_597,
        apiVersion: 9,
        desktopVersion: "0.0.403",
        electronVersion: "42.7.1",
        chromiumVersion: "148.0.7778.280",
        nativeBuildNumber: 87_263,
        apexAppSurface: 2,
        webGatewayEncoding: "json",
        webGatewayCompression: "zlib-stream",
        desktopGatewayEncoding: "etf",
        desktopGatewayCompression: "zstd-stream",
        defaultCapabilities: 1_734_653,
        privateChannelObfuscationCapabilities: 1_767_421,
        qosHeartbeatVersion: 29
    )
}
