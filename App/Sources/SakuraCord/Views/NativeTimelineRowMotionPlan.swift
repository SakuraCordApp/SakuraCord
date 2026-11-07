import CoreGraphics

/// What changed about a followed row in one timeline update.
enum NativeTimelineRowChange {
    case none
    /// Only its reactions changed, so its chips animate.
    case reactions
    /// Its message changed in place, as an edit or new embeds do. The row
    /// shows its new content at once while its height glides.
    case content
    /// Only its grouping with its neighbours changed. Next to a deleted
    /// row it glides like an edit; elsewhere, as when older history
    /// arrives above it, it applies instantly.
    case regroup
    /// Anything else, which applies instantly.
    case other
}

extension NativeMessageTimelineItem {
    func change(from old: Self) -> NativeTimelineRowChange {
        guard old != self else { return .none }
        guard case let .message(oldRow, oldUnread, oldHighlighted) = old,
              case let .message(row, unread, highlighted) = self
        else { return .other }
        if unread == oldUnread, highlighted == oldHighlighted, row.differsOnlyInReactions(from: oldRow) {
            return .reactions
        }
        // A send settling is the send transition's to show.
        guard row.message.outboxState == oldRow.message.outboxState else { return .other }
        return row.message == oldRow.message ? .regroup : .content
    }

    /// Whether an update changed the message's text, which is drawn above
    /// its attachments, embeds and reactions.
    func changesText(from old: Self) -> Bool {
        guard case let .message(oldRow, _, _) = old, case let .message(row, _, _) = self else { return false }
        return row.message.content != oldRow.message.content
    }
}

extension NativeTimelineReactionBaseline {
    /// The rows that stood between two followed rows, when every one of them
    /// has left the timeline; nil when any is missing or merely moved.
    func departedRows(after oldIndex: Int, before nextOldIndex: Int, in departed: Set<Int>) -> [Row]? {
        // Rows that changed order, as Inbox groups can, are no gap.
        guard nextOldIndex > oldIndex + 1 else { return nil }
        let indices = oldIndex + 1 ..< nextOldIndex
        guard indices.allSatisfy(departed.contains) else { return nil }
        return indices.compactMap { rowsByIndex[$0] }
    }

    /// The run of rows right after a followed row that has left the timeline.
    func trailingDepartedRows(after oldIndex: Int, in departed: Set<Int>) -> [Row] {
        var rows: [Row] = []
        while departed.contains(oldIndex + 1 + rows.count), let row = rowsByIndex[oldIndex + 1 + rows.count] {
            rows.append(row)
        }
        return rows
    }
}

/// How the rows around the viewport move in one update. Rows keep the
/// places they had on screen: rows up to the first changed one by `shift`,
/// and each row whose height changed, or whose deleted neighbours left a
/// gap after it, adds a step. An update the steps cannot explain, such as a
/// row inserted between followed rows, describes no motion.
struct NativeTimelineRowMotionPlan {
    struct FollowedRow {
        let oldIndex: Int
        let index: Int
        let identifier: NativeMessageTimelineItem.Identifier
    }

    private(set) var previous: FollowedRow?
    private var followed: [FollowedRow] = []
    private var stepTotals: [Int: CGFloat] = [:]
    private(set) var describesUpdate = true
    private var shift: CGFloat?
    private var expectedShift: CGFloat?
    private var steps: [NativeTimelineReactionRowMotion.Step] = []

    var motion: NativeTimelineReactionRowMotion? {
        guard describesUpdate, let shift, !steps.isEmpty else { return nil }
        return .init(shift: shift, steps: steps)
    }

    /// Follows the next displayed row, which moved by `rowShift` on screen
    /// and changed height by `delta`.
    mutating func follow(_ row: FollowedRow, rowShift: CGFloat, delta: CGFloat) {
        if let expectedShift, abs(rowShift - expectedShift) >= 0.5 { describesUpdate = false }
        previous = row
        followed.append(row)
        shift = shift ?? rowShift
        expectedShift = rowShift - delta
    }

    /// Whether a row changing height by `delta` keeps the rows below it
    /// nearer their places than its own top, as when the newest message
    /// is held at the bottom.
    func holdsRowsBelow(changingBy delta: CGFloat) -> Bool {
        guard let shift else { return false }
        let top = steps.reduce(shift) { $0 - $1.delta }
        return abs(top - delta) < abs(top)
    }

    /// Closes a change of `row`'s height on the rows right before it, so
    /// its new content lands where it ends while they glide to it. A
    /// shrink widens the row before; a growth takes from each row before in
    /// turn no more than `height` says it shows. False, with nothing added,
    /// when those rows, adjacent before and after the update and without
    /// `excluded` gaps below, cannot take all of it.
    mutating func closeAbove(
        _ row: FollowedRow,
        delta: CGFloat,
        excluding excluded: Set<NativeMessageTimelineItem.Identifier>,
        height: (FollowedRow) -> CGFloat
    ) -> Bool {
        var pieces: [(FollowedRow, CGFloat)] = []
        var left = delta
        var next = row
        for candidate in followed.dropLast().reversed() {
            guard abs(left) >= 0.5, candidate.index == next.index - 1, candidate.oldIndex == next.oldIndex - 1,
                  !excluded.contains(candidate.identifier)
            else { break }
            let piece = delta < 0 ? left : min(left, max(0, height(candidate) - (stepTotals[candidate.index] ?? 0)))
            pieces.append((candidate, piece))
            left -= piece
            next = candidate
        }
        guard abs(left) < 0.5 else { return false }
        for (candidate, piece) in pieces { addStep(for: candidate, delta: piece) }
        return true
    }

    mutating func addStep(for row: FollowedRow, delta: CGFloat, closesGap: Bool = false) {
        guard abs(delta) >= 0.5 else { return }
        steps.append(.init(identifier: row.identifier, rowIndex: row.index, delta: delta, closesGap: closesGap))
        stepTotals[row.index, default: 0] += delta
    }

    /// Deleted rows after the last followed row: it keeps the height they
    /// showed and gives it up as the motion runs, so the rows after it
    /// close the gap. `height` is what the rows took in the layout.
    mutating func closeGap(height: CGFloat, shown: CGFloat) {
        guard let previous else { return }
        expectedShift = expectedShift.map { $0 + height }
        addStep(for: previous, delta: -shown, closesGap: true)
    }

    mutating func invalidate() {
        describesUpdate = false
    }
}

/// What one update starts: the row motion, the deleted rows fading with it,
/// and the chip transitions already installed.
struct NativeTimelineUpdateMotion {
    typealias Identifier = NativeMessageTimelineItem.Identifier

    /// Where the rows that left the timeline stood before the update.
    let departedOldIndices: Set<Int>
    /// What rows this update deleted were still showing, now handed to the
    /// row before each of them.
    var handOvers: [Identifier: NativeTimelineCanvasView.HandOver]
    /// The motion this update starts, for the pieces that belong to it.
    let motionID: Int
    var plan = NativeTimelineRowMotionPlan()
    /// A piece joining the run below a row. A new one belongs to this
    /// update's motion; an inherited one keeps its own.
    struct DepartedPiece {
        let anchor: Identifier
        let piece: NativeTimelineDepartedRun.Piece
        let isNew: Bool
    }

    var departedPieces: [DepartedPiece] = []
    var startedChips = false
    var pausesMedia = false
    var droppedMotion = false
}
