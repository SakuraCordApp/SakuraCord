@testable import SakuraCord
import Foundation
import Testing

@MainActor @Test func `official connection icon resources exist for both appearances`() {
    let appDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let resourceDirectory = appDirectory
        .appending(path: "Sources/SakuraCord/Resources/ConnectionIcons", directoryHint: .isDirectory)

    for (type, asset) in ConnectionBrand.officialIconAssets {
        for resourceName in [asset.light, asset.dark] {
            let resourceURL = resourceDirectory.appending(path: "\(resourceName).svg")
            #expect(FileManager.default.fileExists(atPath: resourceURL.path), "Missing icon for \(type)")
        }
    }
}

@MainActor @Test func `connection aliases use the official brand`() {
    #expect(ConnectionBrand.iconAsset(for: "x") != nil)
    #expect(ConnectionBrand.iconAsset(for: "twitter_legacy") != nil)
    #expect(ConnectionBrand.iconAsset(for: "playstation-stg") != nil)
    #expect(ConnectionBrand.displayName(for: "x") == "X")
    #expect(ConnectionBrand.displayName(for: "ebay") == "eBay")
}
