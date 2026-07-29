import CoreGraphics
@testable import SakuraCord
import SakuraCordModels
import Testing

@Suite("Direct message call layout")
@MainActor
struct DirectMessageCallLayoutTests {
    @Test("call height preserves chat space and respects its preferred bounds")
    func callHeightBounds() {
        let ordinary = DirectMessageCallLayout(availableHeight: 800)

        #expect(ordinary.minimumHeight == 210)
        #expect(ordinary.maximumHeight == 568)
        #expect(ordinary.clampedHeight(100) == 210)
        #expect(ordinary.clampedHeight(400) == 400)
        #expect(ordinary.clampedHeight(700) == 568)

        let tall = DirectMessageCallLayout(availableHeight: 1_200)
        #expect(tall.maximumHeight == 640)
    }

    @Test("call region still has a usable bounded height in a short window")
    func shortWindowBounds() {
        let layout = DirectMessageCallLayout(availableHeight: 300)

        #expect(layout.minimumHeight == 150)
        #expect(layout.maximumHeight == 150)
        #expect(layout.clampedHeight(340) == 150)
    }

    @Test("joinable calls do not merge a disconnected local voice session")
    func joinableCallDoesNotMergeLocalVoiceSession() {
        let displayedChannelID = ChannelID(rawValue: 400)

        #expect(
            !VoiceVideoGrid.usesLocalVoiceSession(
                displayedChannelID: displayedChannelID,
                activeVoiceChannelID: nil
            )
        )
        #expect(
            !VoiceVideoGrid.usesLocalVoiceSession(
                displayedChannelID: displayedChannelID,
                activeVoiceChannelID: ChannelID(rawValue: 401)
            )
        )
        #expect(
            VoiceVideoGrid.usesLocalVoiceSession(
                displayedChannelID: displayedChannelID,
                activeVoiceChannelID: displayedChannelID
            )
        )
    }

    @Test(
        "participant cards fit entirely inside every supported compact region",
        arguments: [
            CGSize(width: 420, height: 92),
            CGSize(width: 620, height: 150),
            CGSize(width: 900, height: 210),
            CGSize(width: 1_100, height: 420),
        ],
        Array(1 ... 9)
    )
    func participantCardsNeverOverflow(size: CGSize, participantCount: Int) {
        let layout = VoiceGridLayout.fitted(
            in: size,
            participantCount: participantCount
        )
        let availableWidth = max(1, size.width - VoiceGridLayout.padding * 2)
        let availableHeight = max(1, size.height - VoiceGridLayout.padding * 2)

        #expect(layout.columns >= 1)
        #expect(layout.columns <= participantCount)
        #expect(layout.rows * layout.columns >= participantCount)
        #expect(layout.tileSize.width > 0)
        #expect(layout.tileSize.height > 0)
        #expect(layout.gridSize.width <= availableWidth + 0.001)
        #expect(layout.gridSize.height <= availableHeight + 0.001)
        #expect(
            abs(
                layout.tileSize.width / layout.tileSize.height
                    - VoiceGridLayout.targetAspectRatio
            ) < 0.001
        )
    }

    @Test("participant cards scale down when the call region becomes shorter")
    func participantCardsScaleWithHeight() {
        let tall = VoiceGridLayout.fitted(
            in: CGSize(width: 900, height: 360),
            participantCount: 4
        )
        let short = VoiceGridLayout.fitted(
            in: CGSize(width: 900, height: 92),
            participantCount: 4
        )

        #expect(short.tileSize.height < tall.tileSize.height)
        #expect(short.gridSize.height < tall.gridSize.height)
    }

    @Test("four participants use the arrangement with the largest cards")
    func fourParticipantsUseLargestCards() {
        let shortAndWide = VoiceGridLayout.fitted(
            in: CGSize(width: 900, height: 150),
            participantCount: 4
        )
        let narrow = VoiceGridLayout.fitted(
            in: CGSize(width: 420, height: 150),
            participantCount: 4
        )
        let tallAndWide = VoiceGridLayout.fitted(
            in: CGSize(width: 900, height: 508),
            participantCount: 4
        )

        #expect(shortAndWide.columns == 4)
        #expect(shortAndWide.rows == 1)
        #expect(narrow.columns == 2)
        #expect(narrow.rows == 2)
        #expect(tallAndWide.columns == 2)
        #expect(tallAndWide.rows == 2)
        #expect(
            tallAndWide.tileSize.width > shortAndWide.tileSize.width
        )
        #expect(
            tallAndWide.tileSize.height > shortAndWide.tileSize.height
        )
    }
}
