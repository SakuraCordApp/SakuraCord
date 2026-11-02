@testable import SakuraCord
import Foundation
import Testing

@Test(arguments: [
    ("https://cdn.discordapp.com/attachments/1/2/Setup.EXE?ex=1&hm=2", true),
    ("https://cdn.discordapp.com/attachments/1/2/archive.tar.gz", true),
    ("https://cdn.discordapp.com/attachments/1/2/photo.png", false),
    ("https://cdn.discordapp.com/attachments/1/2/notes.txt?x=a.exe", false),
    ("https://cdn.discordapp.com/attachments/1/2/zip", false),
    ("https://example.com/files/app.dmg/", true),
    ("https://example.com/files/app.dmg/readme/..", true),
    ("https://github.com/owner/repo/releases/download/v1/App.dmg", true),
    ("https://github.com/owner/repo/blob/main/script.py", false),
])
func `Downloads warn exactly where Discord's dangerous file rule does`(url: String, isDangerous: Bool) throws {
    #expect(DangerousDownloadPolicy.isPotentiallyDangerous(try #require(URL(string: url))) == isDangerous)
}
