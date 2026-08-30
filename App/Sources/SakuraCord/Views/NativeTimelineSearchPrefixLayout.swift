import Foundation

struct NativeTimelineSearchPrefixLayout {
    let region: NativeTimelineRowLayout.SearchSectionRegion?
    let height: CGFloat

    static func make(
        context: MessageSearchRowContext?,
        width: CGFloat
    ) -> Self {
        guard let context, context.showsSectionHeader else {
            return Self(region: nil, height: 0)
        }
        let sectionFrame = CGRect(
            x: 14,
            y: 8,
            width: max(1, width - 28),
            height: context.sectionSubtitle == nil ? 24 : 34
        )
        let iconFrame = CGRect(
            x: sectionFrame.minX,
            y: sectionFrame.minY + 2,
            width: 20,
            height: 20
        )
        let titleFrame = CGRect(
            x: iconFrame.maxX + 7,
            y: sectionFrame.minY,
            width: max(1, sectionFrame.maxX - iconFrame.maxX - 7),
            height: 18
        )
        let subtitleFrame = context.sectionSubtitle.map { _ in
            CGRect(
                x: titleFrame.minX,
                y: titleFrame.maxY,
                width: titleFrame.width,
                height: 14
            )
        }
        return Self(
            region: NativeTimelineRowLayout.SearchSectionRegion(
                frame: sectionFrame,
                iconFrame: iconFrame,
                titleFrame: titleFrame,
                subtitleFrame: subtitleFrame
            ),
            height: sectionFrame.maxY + 4
        )
    }
}
