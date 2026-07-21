import Foundation

/// Sanitized protocol constants observed from Discord's production app bootstrap.
/// These values are compatibility fixtures, not a promise of policy compliance.
public struct DiscordProductionBaseline: Codable, Equatable, Sendable {
    public var observedAt: Date
    public var webBuildNumber: Int
    public var apiVersion: Int
    public var desktopVersion: String
    public var electronVersion: String
    public var webGatewayEncoding: String
    public var webGatewayCompression: String
    public var desktopGatewayEncoding: String
    public var desktopGatewayCompression: String
    public var defaultCapabilities: Int

    public static let july2026 = DiscordProductionBaseline(
        observedAt: Date(timeIntervalSince1970: 1_784_240_478),
        webBuildNumber: 579_073,
        apiVersion: 9,
        desktopVersion: "0.0.401",
        electronVersion: "37.6.0",
        webGatewayEncoding: "json",
        webGatewayCompression: "zlib-stream",
        desktopGatewayEncoding: "etf",
        desktopGatewayCompression: "zstd-stream",
        defaultCapabilities: 1_734_653
    )
}
