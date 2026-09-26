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
    static let horizontalInset: CGFloat = 8
    static let verticalInset: CGFloat = 10
    static let sectionHeaderHeight: CGFloat = 34
    static let memberRowHeight: CGFloat = 46
    static let paintedRowHeight: CGFloat = 44
    static let avatarSize: CGFloat = 34
    static let avatarContainerSize: CGFloat = 38.08
    static let presenceIndicatorSize: CGFloat = 11
    static let rowCornerRadius: CGFloat = 9
    static let prewarmItemCount = 8
    static let activityEmojiSize: CGFloat = 15
    static let maximumVisibleAnimatedEmojiCount = 64
}

nonisolated struct NativeMemberListPresentation: Equatable, Sendable {
    var roleColorDisplay: RoleColorDisplay = .inNames
    var isDark = false
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
        HStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                SkeletonShape(
                    cornerRadius: NativeMemberListMetrics.avatarSize / 2
                )
                .frame(
                    width: NativeMemberListMetrics.avatarSize,
                    height: NativeMemberListMetrics.avatarSize
                )

                SkeletonShape(cornerRadius: 5.5)
                    .frame(width: 11, height: 11)
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

            VStack(alignment: .leading, spacing: 9) {
                SkeletonShape(cornerRadius: 5)
                    .frame(width: 104, height: 10)
                SkeletonShape(cornerRadius: 4)
                    .frame(width: 138, height: 8)
                    .opacity(0.7)
            }
            .offset(y: -2.5)

            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct MemberListSkeletonHeader: View {
    var body: some View {
        SkeletonShape(cornerRadius: 5)
            .frame(width: 96, height: 10)
            .padding(.leading, NativeMemberListMetrics.horizontalInset + 10)
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

    static let accessorySpacing: CGFloat = 5

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
