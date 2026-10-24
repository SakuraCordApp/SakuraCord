import AppKit
import SwiftUI

/// Animates the workspace layout changes the reader asks for (opening,
/// closing or widening a side chat, toggling the member list) with the member
/// list's spring. Navigation changes the layout without it and appears at once.
///
/// A trailing column slides in or out as an offset, and on every frame the
/// conversation gives up exactly the width the column covers, so its
/// timeline and composer resize live (`WorkspaceColumnsLayout`). Nothing
/// else in the workspace lays out again per frame; relaying out the whole
/// workspace on every frame cost about 50 ms per frame on an 8 GB Mac. Work
/// that would block the main thread for several frames (a pane's content, a
/// thread's first page, a timeline's full reflow) waits for the motion to
/// settle so the motion keeps every frame.
@MainActor
enum WorkspaceLayoutMotion {
    /// Lets the motion benchmark reach each layout's static reference.
    static var isSuppressedForBenchmark = false

    /// Posted on the main thread as a motion begins and once it settles.
    static let didBegin = Notification.Name("SakuraCordWorkspaceMotionDidBegin")
    static let didSettle = Notification.Name("SakuraCordWorkspaceMotionDidSettle")
    /// Posted on the main thread when columns start to move, with whether
    /// they move animated under `animatesKey`. `WorkspaceColumnsHost` moves
    /// the columns itself, without the view graph.
    static let revealDidChange = Notification.Name("SakuraCordWorkspaceRevealDidChange")
    static let animatesKey = "animates"
    /// Posted on the main thread just before a change that may close a
    /// trailing column, while the columns still show their content.
    static let willChangeColumns = Notification.Name("SakuraCordWorkspaceWillChangeColumns")

    /// When the running motion settles.
    private(set) static var settlesAt: ContinuousClock.Instant?

    /// Nil, so the change snaps, under Reduce Motion or when the reader
    /// turned off any of `categories`, and without a running app, as in unit
    /// tests: a motion's state is shared, and one test's motion held
    /// another's width relayout back.
    private static func springAnimation(for categories: [AppMotionCategory], in model: AppModel) -> Animation? {
        NSApp == nil || isSuppressedForBenchmark || !model.animates(categories)
            ? nil : .spring(ChatChromeMetrics.sidebarSpring)
    }

    static var isMoving: Bool {
        settlesAt.map { ContinuousClock.now < $0 } ?? false
    }

    /// Until the spring is within a thousandth of its target. SwiftUI keeps
    /// animating past `Spring.settlingDuration`, which is shorter.
    private static var settling: Duration {
        .seconds(9.3 * ChatChromeMetrics.sidebarSpring.duration / (2 * .pi))
    }

    /// Opens, closes or swaps the workspace's trailing column. The change
    /// moves only if every one of `categories` does: by default those of a
    /// side chat, and of the member list or search results it takes the place
    /// of or returns.
    static func perform(
        in model: AppModel,
        categories: [AppMotionCategory]? = nil,
        _ change: () -> Void
    ) {
        guard let animation = springAnimation(for: categories ?? model.sideChatMotionCategories, in: model) else {
            withAnimation(nil, change)
            return
        }
        beginMotion()
        let leaving = WorkspaceTrailingColumn(model.workspacePresentation)
        NotificationCenter.default.post(name: willChangeColumns, object: nil)
        // The columns' motion is explicit below and starts from the layout
        // this change commits, so the change itself is not animated.
        withAnimation(nil, change)
        let arriving = WorkspaceTrailingColumn(model.workspacePresentation)
        slideTrailingColumns(from: leaving, to: arriving, animation)
    }

    /// Slides the column that leaves out and the one that arrives in.
    private static func slideTrailingColumns(
        from leaving: WorkspaceTrailingColumn?,
        to arriving: WorkspaceTrailingColumn?,
        _ animation: Animation
    ) {
        let phase = WorkspaceMotionPhase.shared
        guard leaving?.id != arriving?.id else { return }
        // Each write to the phase invalidates its observers, so write once.
        var departing = phase.departing.filter { $0.id != leaving?.id && $0.id != arriving?.id }
        if let leaving {
            // The column that leaves stays until it is out of view, beneath
            // any column that arrives.
            departing.append(leaving)
        }
        if departing != phase.departing { phase.departing = departing }
        if let arriving, phase.reveal[arriving.id] == nil {
            phase.reveal[arriving.id] = 0
            NotificationCenter.default.post(name: revealDidChange, object: nil, userInfo: [animatesKey: false])
        }
        // Columns move from the frame that commits the change: an arriving
        // column from beyond the trailing edge, or from wherever it is if it
        // was still leaving.
        afterCommit(animation) {
            if let leaving { phase.reveal[leaving.id] = 0 }
            if let arriving { phase.reveal[arriving.id] = 1 }
            NotificationCenter.default.post(name: revealDidChange, object: nil, userInfo: [animatesKey: true])
        }
    }

    /// Moves the open side chat from the pane to full width: it grows from
    /// the pane's width over the conversation, which stays beneath it until
    /// it is covered, and the inspector slides in beside it if shown.
    static func widen(in model: AppModel, _ change: () -> Void) {
        let before = model.workspacePresentation
        guard let animation = springAnimation(for: model.sideChatMotionCategories, in: model), case .channel(let channel) = before.primary else {
            withAnimation(nil, change)
            return
        }
        beginMotion()
        let phase = WorkspaceMotionPhase.shared
        withAnimation(nil) {
            phase.widening = .init(channel: channel)
            phase.wideningHasArrived = false
            change()
        }
        let inspector = WorkspaceTrailingColumn(model.workspacePresentation)
        slideTrailingColumns(from: nil, to: inspector, animation)
        afterCommit(animation) {
            phase.wideningHasArrived = true
            NotificationCenter.default.post(name: revealDidChange, object: nil, userInfo: [animatesKey: true])
        }
    }

    /// Animates `change` once the frame that commits the layout has been
    /// laid out, which can take a while; the motion settles a spring's
    /// duration after that.
    private static func afterCommit(_ animation: Animation, _ change: @escaping () -> Void) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                settlesAt = .now + settling
                withAnimation(animation, change)
            }
        }
    }

    /// Keeps the running motion from settling until a spring's duration
    /// from now, for a column whose motion started late
    /// (`WorkspaceColumnsHost`).
    static func extendSettling() {
        guard isMoving else { return }
        settlesAt = .now + settling
    }

    /// Returns once no motion is running.
    /// Returns early if the waiting task is cancelled.
    static func untilSettled() async {
        while let settlesAt, ContinuousClock.now < settlesAt {
            do {
                try await Task.sleep(until: settlesAt)
            } catch {
                return
            }
        }
    }

    private static func beginMotion() {
        let phase = WorkspaceMotionPhase.shared
        settlesAt = .now + settling
        if !phase.isMoving {
            phase.isMoving = true
            // Views moving under a still pointer would otherwise rebuild
            // their cursor rectangles on every frame.
            movingWindow = workspaceWindow
            movingWindow?.disableCursorRects()
            NotificationCenter.default.post(name: didBegin, object: nil)
        }
        phase.settleTask?.cancel()
        phase.settleTask = Task {
            await untilSettled()
            guard !Task.isCancelled else { return }
            // Each write invalidates the phase's readers, so skip no-ops.
            withAnimation(nil) {
                phase.isMoving = false
                if phase.widening != nil { phase.widening = nil }
                if phase.wideningHasArrived { phase.wideningHasArrived = false }
                if !phase.departing.isEmpty { phase.departing.removeAll() }
                if !phase.reveal.isEmpty { phase.reveal.removeAll() }
            }
            // The window the motion began in, though another may be main now.
            if let window = movingWindow {
                movingWindow = nil
                window.enableCursorRects()
                window.invalidateCursorRects(for: window.contentView ?? NSView())
            }
            NotificationCenter.default.post(name: didSettle, object: nil)
        }
    }

    private static weak var movingWindow: NSWindow?

    private static var workspaceWindow: NSWindow? {
        // No application object exists in unit tests.
        guard let app = NSApp else { return nil }
        return app.mainWindow ?? app.windows.first { $0.isVisible && $0.canBecomeMain }
    }
}

/// A column that slides in at the workspace's trailing edge: a side chat
/// pane or the inspector (member list or search results).
struct WorkspaceTrailingColumn: Identifiable, Equatable {
    enum Content: Equatable {
        case sideConversation(SideConversation)
        case inspector(SupplementaryPane)
    }

    let content: Content
    /// Which content the column shows, ignoring changes to it.
    let id: String

    /// The column at the trailing edge of a workspace, if any. A full-width
    /// thread is not one; the inspector beside it is.
    init?(_ presentation: WorkspacePresentation) {
        switch presentation.supplementaryPane {
        case .sideConversation(let conversation)?: self.init(.sideConversation(conversation))
        case let pane?: self.init(.inspector(pane))
        case nil: return nil
        }
    }

    init(_ content: Content) {
        self.content = content
        id = switch content {
        case .sideConversation(let conversation): "side-\(conversation.motionIdentity)"
        case .inspector(.memberInspector): "members"
        case .inspector: "search"
        }
    }
}

extension SideConversation {
    /// Which side chat this is, ignoring whether it is in the pane or at
    /// full width.
    var motionIdentity: String {
        switch self {
        case .thread(let thread, _): "thread-\(thread.id)"
        case .threadCreation: "thread-creation"
        case .voiceChat(let channelID): "voice-\(channelID)"
        case .guideResource(_, let channelID): "resource-\(channelID)"
        case .channelPreview(let channelID, _): "preview-\(channelID)"
        }
    }
}

/// Workspace state that exists only while a motion runs.
@MainActor
@Observable
final class WorkspaceMotionPhase {
    struct Widening {
        /// The conversation kept beneath the widening side chat.
        let channel: WorkspacePresentation.ChannelContent
    }

    static let shared = WorkspaceMotionPhase()

    /// Whether a motion runs, so the columns' widths follow it per frame.
    var isMoving = false
    var widening: Widening?
    /// Whether the widening side chat is sliding to the leading edge yet.
    /// `WorkspaceColumnsHost` reads it unobserved, on `revealDidChange`,
    /// so its start updates no view.
    var wideningHasArrived = false {
        didSet { unobservedWideningHasArrived = wideningHasArrived }
    }
    @ObservationIgnored private(set) var unobservedWideningHasArrived = false
    /// Columns that have left the workspace but are still sliding away.
    var departing: [WorkspaceTrailingColumn] = []
    /// How far each moving column has come in, from 0 (beyond the trailing
    /// edge) to 1 (in place). Columns at rest are absent.
    var reveal: [String: CGFloat] = [:] {
        didSet { unobservedReveal = reveal }
    }
    /// `reveal`, for `WorkspaceColumnsHost`: it moves the columns itself,
    /// so reading it must not update the view graph.
    @ObservationIgnored private(set) var unobservedReveal: [String: CGFloat] = [:]
    @ObservationIgnored fileprivate var settleTask: Task<Void, Never>?

    private init() {}

    func reveal(of id: String) -> CGFloat {
        reveal[id] ?? 1
    }
}
