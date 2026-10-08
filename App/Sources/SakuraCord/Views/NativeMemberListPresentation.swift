import AppKit
import CoreText
import OSLog
import SakuraCordModels
import SwiftUI

extension Member {
    nonisolated var isListedOnline: Bool {
        isOnline || user.usesHTTPInteractions
    }

    nonisolated var memberListStatus: PresenceStatus? {
        user.usesHTTPInteractions ? nil : status
    }

    nonisolated var memberListActivityText: String? {
        if isListeningToMusic, let customStatus, !customStatus.isEmpty {
            return customStatus
        }
        return activityText
    }

    nonisolated var memberListShowsMusicSeparator: Bool {
        isListeningToMusic && customStatus?.isEmpty == false
    }
}

nonisolated enum NativeMemberListMetrics {
    static var horizontalInset: CGFloat { InterfaceScale.metric(8) }
    static var verticalInset: CGFloat { InterfaceScale.metric(10) }
    static var sectionHeaderHeight: CGFloat { InterfaceScale.metric(34) }
    static var memberRowHeight: CGFloat { InterfaceScale.metric(46) }
    static var paintedRowHeight: CGFloat { InterfaceScale.metric(44) }
    static var avatarSize: CGFloat { InterfaceScale.metric(34) }
    static var avatarContainerSize: CGFloat { InterfaceScale.metric(38.08) }
    static var presenceIndicatorSize: CGFloat { InterfaceScale.metric(11) }
    static var rowCornerRadius: CGFloat { InterfaceScale.metric(9) }
    static let prewarmItemCount = 8
    static var activityEmojiSize: CGFloat { InterfaceScale.metric(15) }
    static let maximumVisibleAnimatedEmojiCount = 64
}

nonisolated struct NativeMemberListPresentation: Equatable, Sendable {
    var roleColorDisplay: RoleColorDisplay = .inNames
    var isDark = false
    /// Rows are measured and drawn at this interface size.
    var interfaceScale = InterfaceScale.factor
    /// Member lists fade offline rows; a friends list does not.
    var dimsOfflineMembers = true
    /// Rows such as pending friend requests that show no presence.
    var presenceHiddenUserIDs: Set<UserID> = []
    /// Space reserved for hover controls on wider people lists.
    var trailingAccessoryWidth: CGFloat = 0

    func opacity(for member: Member) -> CGFloat {
        dimsOfflineMembers && !member.isListedOnline ? 0.55 : 1
    }

    func status(for member: Member) -> PresenceStatus? {
        presenceHiddenUserIDs.contains(member.id) ? nil : member.memberListStatus
    }
}

nonisolated enum MemberListSkeletonLayout {
    enum Item: Hashable {
        case header(Int)
        case member(section: Int, row: Int)

        var height: CGFloat {
            switch self {
            case .header: NativeMemberListMetrics.sectionHeaderHeight
            case .member: NativeMemberListMetrics.memberRowHeight
            }
        }
    }

    static func itemsFitting(height: CGFloat, memberCounts: [Int]) -> [Item] {
        let availableHeight = max(
            0,
            height - NativeMemberListMetrics.verticalInset * 2
        )
        var result: [Item] = []
        var usedHeight: CGFloat = 0
        for (section, count) in memberCounts.enumerated() {
            let header = Item.header(section)
            guard usedHeight + header.height <= availableHeight else { break }
            result.append(header)
            usedHeight += header.height
            for row in 0 ..< count {
                let member = Item.member(section: section, row: row)
                guard usedHeight + member.height <= availableHeight else {
                    return result
                }
                result.append(member)
                usedHeight += member.height
            }
        }
        return result
    }
}

struct MemberListSkeletonRow: View {
    var body: some View {
        HStack(spacing: InterfaceScale.metric(8)) {
            ZStack(alignment: .bottomTrailing) {
                SkeletonShape(
                    cornerRadius: NativeMemberListMetrics.avatarSize / 2
                )
                .frame(
                    width: NativeMemberListMetrics.avatarSize,
                    height: NativeMemberListMetrics.avatarSize
                )

                SkeletonShape(cornerRadius: InterfaceScale.metric(5.5))
                    .frame(width: InterfaceScale.metric(11), height: InterfaceScale.metric(11))
                    .overlay {
                        Circle().stroke(
                            Color(nsColor: .controlBackgroundColor),
                            lineWidth: 2
                        )
                    }
                    .offset(x: 1, y: 1)
            }
            .frame(
                width: NativeMemberListMetrics.avatarContainerSize,
                height: NativeMemberListMetrics.avatarContainerSize
            )

            VStack(alignment: .leading, spacing: InterfaceScale.metric(9)) {
                SkeletonShape(cornerRadius: InterfaceScale.metric(5))
                    .frame(width: InterfaceScale.metric(104), height: InterfaceScale.metric(10))
                SkeletonShape(cornerRadius: InterfaceScale.metric(4))
                    .frame(width: InterfaceScale.metric(138), height: InterfaceScale.metric(8))
                    .opacity(0.7)
            }
            .offset(y: -InterfaceScale.metric(2.5))

            Spacer(minLength: 0)
        }
        .padding(.leading, InterfaceScale.metric(4))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct MemberListSkeletonHeader: View {
    var body: some View {
        SkeletonShape(cornerRadius: InterfaceScale.metric(5))
            .frame(width: InterfaceScale.metric(96), height: InterfaceScale.metric(10))
            .padding(.leading, NativeMemberListMetrics.horizontalInset + InterfaceScale.metric(10))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

nonisolated enum NativeMemberNameLayout {
    struct Result: Equatable {
        let nameWidth: CGFloat
        let accessoryFrames: [CGRect]
    }

    static var accessorySpacing: CGFloat { InterfaceScale.metric(5) }

    static func layout(
        measuredNameWidth: CGFloat,
        availableWidth: CGFloat,
        accessoryWidths: [CGFloat]
    ) -> Result {
        let availableWidth = max(0, availableWidth)
        let accessoryWidths = accessoryWidths.map { max(0, $0) }
        let totalAccessoryWidth = accessoryWidths.reduce(0, +)
        let totalSpacing = accessorySpacing * CGFloat(accessoryWidths.count)
        let nameWidth = min(
            max(0, measuredNameWidth),
            max(0, availableWidth - totalAccessoryWidth - totalSpacing)
        )
        var cursor = nameWidth
        let frames = accessoryWidths.map { width in
            cursor += accessorySpacing
            let remainingWidth = max(0, availableWidth - cursor)
            let visibleWidth = min(width, remainingWidth)
            let frame = CGRect(x: cursor, y: 0, width: visibleWidth, height: 0)
            cursor += visibleWidth
            return frame
        }
        return Result(nameWidth: nameWidth, accessoryFrames: frames)
    }
}
