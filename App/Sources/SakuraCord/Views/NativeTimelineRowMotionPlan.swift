import CoreGraphics

/// What changed about a followed row in one timeline update.
enum NativeTimelineRowChange {
    case none
    /// Only its reactions changed, so its chips animate.
    case reactions
    /// Its message changed in place, as an edit or new embeds do. Its
    /// height glides, and lines an edit adds or removes fade as their space
    /// opens or closes.
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
        // A send settling is the send transition's to show, unless it brings
        // content, as a link preview Discord already had cached does.
        if row.message.outboxState != oldRow.message.outboxState {
            return row.message.embeds == oldRow.message.embeds && row.message.components == oldRow.message.components
                ? .other : .content
        }
        return row.message == oldRow.message ? .regroup : .content
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
        shift = shift ?? rowShift
        expectedShift = rowShift - delta
    }

    mutating func addStep(for row: FollowedRow, delta: CGFloat, closesGap: Bool = false, movesText: Bool = false) {
        guard abs(delta) >= 0.5 else { return }
        steps.append(.init(identifier: row.identifier, rowIndex: row.index, delta: delta, closesGap: closesGap, movesText: movesText))
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
    /// The text of edited rows whose lines fade with this motion.
    var textBands: [NativeTimelineEditedTextBand] = []
    /// A piece joining the run below a row. A new one belongs to this
    /// update's motion; an inherited one keeps its own.
    struct DepartedPiece {
        let anchor: Identifier
        var piece: NativeTimelineDepartedRun.Piece
        let isNew: Bool
    }

    var departedPieces: [DepartedPiece] = []
    var startedChips = false
    var pausesMedia = false
    var droppedMotion = false
}
