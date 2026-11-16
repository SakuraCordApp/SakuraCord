import Foundation

public enum UploadFilename {
    /// Discord marks an attachment as a spoiler by this filename prefix.
    public static let spoilerPrefix = "SPOILER_"

    public static func anonymised(_ filename: String) -> String {
        let fileExtension = (filename as NSString).pathExtension
        let basename = UUID().uuidString.lowercased()
        let name = fileExtension.isEmpty ? basename : "\(basename).\(fileExtension)"
        return filename.hasPrefix(spoilerPrefix) ? spoilerPrefix + name : name
    }
}
