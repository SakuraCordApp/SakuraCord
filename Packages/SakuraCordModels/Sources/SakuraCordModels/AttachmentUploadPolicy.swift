import Foundation

public enum DiscordAttachmentUploadPolicy {
    public static let mebibyte: Int64 = 1_024 * 1_024
    public static let baseLimit = 20 * mebibyte
    public static let basicAndClassicLimit = 50 * mebibyte
    public static let nitroLimit = 500 * mebibyte

    public static func maximumFileSize(premiumType: Int) -> Int64 {
        switch premiumType {
        case 1, 3:
            basicAndClassicLimit
        case 2:
            nitroLimit
        default:
            baseLimit
        }
    }

    public static func allows(fileSize: Int64, premiumType: Int) -> Bool {
        fileSize <= maximumFileSize(premiumType: premiumType)
    }
}
