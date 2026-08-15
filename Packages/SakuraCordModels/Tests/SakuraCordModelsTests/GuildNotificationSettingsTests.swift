import Foundation
@testable import SakuraCordModels
import Testing

@Test func `legacy guild notification settings decode current defaults`() throws {
    let data = Data(
        #"{"guildID":"100","messageNotifications":1,"isMuted":false,"suppressEveryone":true,"suppressRoles":false,"flags":0,"channelOverrides":[]}"#.utf8
    )

    let settings = try JSONDecoder().decode(GuildNotificationSettings.self, from: data)

    #expect(settings.guildID == GuildID(rawValue: 100))
    #expect(settings.notifyHighlights == .inherit)
    #expect(!settings.muteScheduledEvents)
    #expect(settings.mobilePush)
}

@Test func `guild notification toggles update their canonical fields`() {
    var settings = GuildNotificationSettings(guildID: GuildID(rawValue: 100))

    for toggle in GuildNotificationToggle.allCases {
        settings.set(toggle, isEnabled: true)
        #expect(settings.isEnabled(toggle))
        settings.set(toggle, isEnabled: false)
        #expect(!settings.isEnabled(toggle))
    }
    #expect(settings.notifyHighlights == .inherit)
}
