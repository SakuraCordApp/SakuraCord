import Foundation
@testable import SakuraCordModels
import Testing

@Test func `attachments open as text and play as Discord classifies them`() {
    func attachment(_ filename: String, type: String? = nil, width: Int? = nil) -> SakuraCordModels.Attachment {
        SakuraCordModels.Attachment(id: filename, filename: filename, url: URL(string: "https://cdn.discordapp.com/\(filename)")!,
                   mediaType: type, width: width, height: width)
    }
    // Discord labels .m4a as video/mp4, yet plays it as audio.
    #expect(attachment("voice.m4a", type: "video/mp4").mediaKind == .audio)
    #expect(attachment("clip.mp4", type: "video/mp4", width: 320).mediaKind == .video)
    #expect(attachment("song.aac", type: "audio/aac").mediaKind == .file)
    #expect(attachment("main.swift", type: "text/plain").textPreviewLanguage == "swift")
    #expect(attachment("makefile").textPreviewLanguage == "makefile")
    // The extension match is case-sensitive, as Discord's is.
    #expect(attachment("NOTES.TXT").textPreviewLanguage == nil)
    #expect(attachment("archive.zip").textPreviewLanguage == nil)
}
