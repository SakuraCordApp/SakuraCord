import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Uploads, stored attachments and link unfurling.
public extension World {
    /// Reserves a slot on the attachment host. Discord's names are `<uuid>/<filename>`.
    /// The slot belongs to `owner` posting in `channel`; nobody else can attach it.
    func reserveUpload(filename: String, owner: Snowflake, channel: Snowflake) -> String {
        let uuid = String(format: "%08x-%04x-4%03x-a%03x-%012llx", UInt32(truncatingIfNeeded: random.next()),
                          UInt16(truncatingIfNeeded: random.next()), UInt16(truncatingIfNeeded: random.next()) & 0xFFF,
                          UInt16(truncatingIfNeeded: random.next()) & 0xFFF, random.next() & 0xFFFF_FFFF_FFFF)
        let name = "\(uuid)/\(filename)"
        pendingUploads[name] = PendingUpload(filename: filename, owner: owner, channel: channel)
        return name
    }

    /// The upload host received the bytes for a reserved slot.
    func completeUpload(_ name: String, data: Data) -> Bool {
        guard pendingUploads[name] != nil else { return false }
        pendingUploads[name]?.data = data
        return true
    }

    /// Not captured: Discord's answer for an unknown or someone else's name; it stays 204 here.
    func discardUpload(_ name: String, owner: Snowflake) {
        if pendingUploads[name]?.owner == owner { pendingUploads[name] = nil }
    }

    func takeUpload(_ name: String, owner: Snowflake, channel: Snowflake) -> Data? {
        guard let upload = pendingUploads[name], upload.owner == owner, upload.channel == channel, let data = upload.data else { return nil }
        pendingUploads[name] = nil
        return data
    }

    /// Stores bytes as an attachment on the CDN and reads image dimensions like Discord does.
    func storeAttachment(_ data: Data, filename: String, channelID: Snowflake, description: String?,
                         durationSeconds: Double?, waveform: String?, flags: Int) -> Attachment {
        let id = nextID()
        let contentType = Self.contentType(forFilename: filename, data: data)
        var attachment = Attachment(id: id, filename: filename, size: data.count, contentType: contentType,
                                    cdnPath: "/attachments/\(channelID)/\(id)/\(filename)")
        attachment.description = description
        attachment.durationSeconds = durationSeconds
        attachment.waveform = waveform
        attachment.flags = flags
        attachment.spoiler = filename.hasPrefix("SPOILER_")
        if contentType.hasPrefix("image/"), let source = CGImageSourceCreateWithData(data as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            attachment.width = properties[kCGImagePropertyPixelWidth] as? Int
            attachment.height = properties[kCGImagePropertyPixelHeight] as? Int
            attachment.placeholder = ThumbHash.placeholder(for: data)
        }
        media[attachment.cdnPath] = (data, contentType)
        return attachment
    }

    internal nonisolated static func contentType(forFilename filename: String, data: Data) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "ogg": return "audio/ogg"
        case "txt": return "text/plain; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        default: return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        }
    }

    /// The `message_snapshots` entry Discord stores for a forward.
    func renderForwardSnapshot(_ original: Message) -> JSON {
        guard case let .object(full) = renderMessage(original, viewer: nil, depth: 1) else { return .null }
        var inner = JSONObject()
        for key in ["type", "content", "mentions", "mention_roles", "attachments", "embeds", "timestamp",
                    "edited_timestamp", "flags", "components"] {
            if let value = full[key] { inner[key] = value }
        }
        return .object(JSONObject([("message", .object(inner))]))
    }

    /// Discord fetches linked pages and adds embeds in a follow-up MESSAGE_UPDATE.
    /// The simulator knows pages it generated; other links get no embed.
    func unfurlLinks(in message: Message) async {
        guard message.embeds.isEmpty, let unfurler else { return }
        let embeds = unfurler(message.content)
        guard !embeds.isEmpty else { return }
        try? await attachUnfurledEmbeds(message.id, in: message.channelID, embeds: embeds)
    }
}
