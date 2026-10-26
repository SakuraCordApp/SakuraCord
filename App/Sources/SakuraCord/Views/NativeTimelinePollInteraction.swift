import AppKit
import QuartzCore
import SakuraCordModels
import SwiftUI

extension NativeTimelineCanvasView {
    struct PollPointerHit {
        let target: NativeTimelinePollTarget
        let message: Message
        let frame: CGRect
    }

    func pollPointerHit(at point: CGPoint) -> PollPointerHit? {
        guard WindowModalCoordinator.allowsInput(for: self),
              let index = rowIndex(at: point.y), layouts.indices.contains(index), items.indices.contains(index),
              case let .message(row, _, _) = items[index] else { return nil }
        let origin = displayedRowOrigin(at: index)
        let local = CGPoint(x: point.x, y: point.y - origin)
        if let frame = layouts[index].pollResultFrame,
           NativeTimelinePollLayout.resultButtonFrame(in: frame).contains(local) {
            return PollPointerHit(target: .init(messageID: row.id, control: .original), message: row.message,
                                  frame: frame.offsetBy(dx: 0, dy: origin))
        }
        guard let poll = row.message.poll, let layout = layouts[index].pollLayout else { return nil }
        guard layout.frame.contains(local) else { return nil }
        let state = pollStates[row.id] ?? .init()
        let control: NativeTimelinePollTarget.Control
        let frame: CGRect
        if let answer = layout.answers.first(where: { $0.frame.contains(local) }) {
            control = .answer(answer.id); frame = answer.frame
        } else if layout.votesFrame.contains(local) {
            control = .votes; frame = layout.votesFrame
        } else if !poll.isClosed(), layout.revealFrame.contains(local), poll.selectedAnswerIDs.isEmpty {
            control = .reveal; frame = layout.revealFrame
        } else if !poll.isClosed(), layout.submitFrame.contains(local),
                  model?.canUpdatePollVote(on: row.message, removing: !poll.selectedAnswerIDs.isEmpty) == true,
                  !poll.selectedAnswerIDs.isEmpty || (!state.showsResults(for: poll) && !state.selected.isEmpty) {
            control = .submit; frame = layout.submitFrame
        } else { return nil }
        return PollPointerHit(target: .init(messageID: row.id, control: control), message: row.message,
                              frame: frame.offsetBy(dx: 0, dy: origin))
    }

    func setHoveredPollTarget(_ target: NativeTimelinePollTarget?) {
        guard hoveredPollTarget != target else { return }
        hoveredPollTarget = target
        setNeedsDisplay(visibleRect)
    }

    func pollPresentation(for id: MessageID?) -> NativeTimelinePollPresentation {
        guard let id else { return .init() }
        var state = pollStates[id] ?? .init()
        if !suppressesHoverPresentation, !overlayBlocksInteractions, hoveredPollTarget?.messageID == id {
            state.hoveredControl = hoveredPollTarget?.control
        }
        if pressedPollTarget?.messageID == id, hoveredPollTarget == pressedPollTarget {
            state.pressedControl = pressedPollTarget?.control
        }
        if let animation = pollAnimations[id], let poll = pollSnapshots[id] {
            let progress = min(1, max(0, (CACurrentMediaTime() - animation.start) / NativeTimelinePollPresentation.voteAnimationDuration))
            let eased = NativeTimelineComponentButtonVisualState.easeOut(CGFloat(progress))
            for answer in poll.answers {
                let target = poll.totalVotes > 0 ? CGFloat(poll.count(for: answer.id)) / CGFloat(poll.totalVotes) : 0
                let old = animation.from[answer.id] ?? 0
                state.fractions[answer.id] = old + (target - old) * eased
            }
        }
        return state
    }

    func reconcilePollPresentations() {
        let accountID = model?.currentUser?.id
        if pollAccountID != accountID {
            pollStates.removeAll(); pollSnapshots.removeAll(); pollAnimations.removeAll()
            pollPopover?.close(); pollPopover = nil
            pollAccountID = accountID
        }
        var snapshots: [MessageID: MessagePoll] = [:]
        pollRowIndexes.removeAll(keepingCapacity: true)
        for (index, item) in items.enumerated() {
            guard case let .message(row, _, _) = item, let poll = row.message.poll else { continue }
            snapshots[row.id] = poll
            pollRowIndexes[row.id] = index
            let state = pollStates[row.id] ?? .init()
            if rowFrame(at: index).intersects(visibleRect), let previous = pollSnapshots[row.id], previous.results != poll.results,
               state.showsResults(for: poll), AppMotionPolicy.animatesUncategorized {
                // Bars grow from zero when a vote first reveals the results.
                let wasShowingResults = state.showsResults(for: previous)
                let current = pollPresentation(for: row.id)
                let fractions = Dictionary(uniqueKeysWithValues: previous.answers.map { answer in
                    (answer.id, !wasShowingResults ? 0 : current.fractions[answer.id]
                        ?? (previous.totalVotes > 0 ? CGFloat(previous.count(for: answer.id)) / CGFloat(previous.totalVotes) : 0))
                })
                pollAnimations[row.id] = (fractions, CACurrentMediaTime())
            }
            if let previous = pollSnapshots[row.id], !previous.selectedAnswerIDs.isEmpty, poll.selectedAnswerIDs.isEmpty {
                pollStates[row.id]?.revealsResults = false
                pollStates[row.id]?.selected = []
            }
        }
        pollSnapshots = snapshots
        pollStates = pollStates.filter { snapshots[$0.key] != nil }
        pollAnimations = pollAnimations.filter { snapshots[$0.key] != nil }
        startPollAnimationTicker()
        pollClockTask?.cancel()
        if let expiry = snapshots.values.compactMap(\.expiry).filter({ $0 > .now }).min() {
            let delay = min(30, max(0.05, expiry.timeIntervalSinceNow))
            pollClockTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                self.setNeedsDisplay(self.visibleRect)
                self.reconcilePollPresentations()
            }
        }
    }

    private func startPollAnimationTicker() {
        guard !pollAnimations.isEmpty else { return }
        pollAnimationTicker.start(on: self) { [weak self] in
            guard let self else { return }
            for id in self.pollAnimations.keys {
                if let index = self.pollRowIndexes[id] { self.setNeedsDisplay(self.rowFrame(at: index)) }
            }
            self.pollAnimations = self.pollAnimations.filter { CACurrentMediaTime() - $0.value.start < NativeTimelinePollPresentation.voteAnimationDuration }
            if self.pollAnimations.isEmpty { self.pollAnimationTicker.stop() }
        }
    }

    func activatePoll(_ hit: PollPointerHit) {
        guard let model, hit.message.outboxState == .confirmed else { return }
        if hit.target.control == .original {
            if let reference = hit.message.messageReference, let messageID = reference.messageID {
                model.navigate(to: hit.message.guildID, channelID: reference.channelID ?? hit.message.channelID, messageID: messageID)
            }
            return
        }
        guard let poll = hit.message.poll else { return }
        let id = hit.message.id
        var state = pollStates[id] ?? .init()
        switch hit.target.control {
        case .original: break
        case .answer(let answerID):
            if state.showsResults(for: poll) {
                showPollVoters(hit, answerID: answerID)
            } else if !poll.isClosed(), poll.layoutType == 1 {
                if state.selected.contains(answerID) { state.selected.remove(answerID) } else if poll.allowsMultipleAnswers { state.selected.insert(answerID) } else { state.selected = [answerID] }
                pollStates[id] = state
            }
        case .votes:
            showPollVoters(hit, answerID: poll.answers.first?.id ?? 1)
        case .reveal:
            state.revealsResults.toggle()
            pollStates[id] = state
            if state.revealsResults, poll.results == nil { Task { await model.loadUnknownPollResults(hit.message) } }
            if state.revealsResults, poll.results != nil, AppMotionPolicy.animatesUncategorized {
                pollAnimations[id] = (Dictionary(uniqueKeysWithValues: poll.answers.map { ($0.id, 0) }), CACurrentMediaTime())
                startPollAnimationTicker()
            }
        case .submit:
            submitPollVote(hit.message, poll: poll, state: state, model: model)
        }
        refreshPollAccessibility(messageID: id)
        setNeedsDisplay(visibleRect)
    }

    private func submitPollVote(_ message: Message, poll: MessagePoll, state: NativeTimelinePollPresentation, model: AppModel) {
        let removing = !poll.selectedAnswerIDs.isEmpty
        guard model.canUpdatePollVote(on: message, removing: !poll.selectedAnswerIDs.isEmpty), !poll.isClosed(), poll.layoutType == 1,
              removing || (!state.showsResults(for: poll) && !state.selected.isEmpty) else { return }
        // The model applies the vote before the request; unknown tallies show
        // results while they load.
        pollStates[message.id] = .init(revealsResults: !removing && poll.results == nil)
        if !model.vote(on: message, answerIDs: removing ? [] : state.selected) { pollStates[message.id] = state }
    }

    private func refreshPollAccessibility(messageID: MessageID) {
        guard let item = items.first(where: { $0.messageID == messageID }) else { return }
        rebuildAccessibilityProxy(for: item.identifier)
    }

    private func showPollVoters(_ hit: PollPointerHit, answerID: Int) {
        guard let model else { return }
        pollPopover?.close()
        pollPopover = presentMessagePeoplePopover(relativeTo: hit.frame) { popover in
            PollVotersView(model: model, message: hit.message, initialAnswerID: answerID, dismiss: { [weak popover] in popover?.close() })
        }
    }
}

extension NativeTimelineCanvasView {
    func installPollCursors(at index: Int, rowOrigin: CGFloat) {
        if let frame = layouts[index].pollResultFrame {
            addCursorRect(NativeTimelinePollLayout.resultButtonFrame(in: frame).offsetBy(dx: 0, dy: rowOrigin), cursor: .pointingHand)
        }
        guard case let .message(row, _, _) = items[index], row.message.outboxState == .confirmed,
              let poll = row.message.poll, let layout = layouts[index].pollLayout else { return }
        var frames = layout.answers.map(\.frame) + [layout.votesFrame]
        if !poll.isClosed() {
            if poll.selectedAnswerIDs.isEmpty { frames.append(layout.revealFrame) }
            let state = pollPresentation(for: row.id)
            if model?.canUpdatePollVote(on: row.message, removing: !poll.selectedAnswerIDs.isEmpty) == true,
               !poll.selectedAnswerIDs.isEmpty || (!state.showsResults(for: poll) && !state.selected.isEmpty) {
                frames.append(layout.submitFrame)
            }
        }
        for frame in frames { addCursorRect(frame.offsetBy(dx: 0, dy: rowOrigin), cursor: .pointingHand) }
    }

    func requestEndPoll(_ message: Message) {
        guard let model, let window, message.outboxState == .confirmed,
              message.author.id == model.currentUser?.id, message.poll?.isClosed() == false else { return }
        let alert = NSAlert()
        alert.messageText = "End this poll now?"
        alert.informativeText = "This will close the poll immediately and reveal the results."
        alert.addButton(withTitle: "End Poll")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in await model.endPoll(message) }
        }
    }
}

extension NativeTimelineCanvasView {
    func appendPollAccessibility(to children: inout [Any], message: Message, layout: NativeTimelineRowLayout,
                                 rowIndex: Int, parent: NSAccessibilityElement) {
        func append(_ control: NativeTimelinePollTarget.Control, label: String, frame: CGRect, enabled: Bool = true) {
            let target = NativeTimelinePollTarget(messageID: message.id, control: control)
            let hit = PollPointerHit(target: target, message: message,
                                     frame: frame.offsetBy(dx: 0, dy: displayedRowOrigin(at: rowIndex)))
            children.append(accessibilityElement(role: .button, label: label,
                frame: accessibilityChildFrame(frame, rowIndex: rowIndex), parent: parent,
                isEnabled: enabled && message.outboxState == .confirmed, press: { [weak self] in
                    guard let self else { return false }
                    self.activatePoll(hit)
                    return true
                }))
        }
        if let frame = layout.pollResultFrame {
            append(.original, label: "View Poll", frame: NativeTimelinePollLayout.resultButtonFrame(in: frame))
        }
        guard let poll = message.poll, let layout = layout.pollLayout else { return }
        let state = pollPresentation(for: message.id)
        let results = state.showsResults(for: poll)
        children.append(accessibilityElement(role: .staticText, label: poll.question,
            frame: accessibilityChildFrame(layout.questionFrame, rowIndex: rowIndex), parent: parent))
        for region in layout.answers {
            guard let answer = poll.answers.first(where: { $0.id == region.id }) else { continue }
            let count = poll.results == nil ? "Votes unavailable" : "\(poll.count(for: answer.id)) \(poll.count(for: answer.id) == 1 ? "vote" : "votes")"
            let label = results
                ? "\(answer.text), \(count)\(poll.selectedAnswerIDs.contains(answer.id) ? ", you voted" : ""), show voters"
                : "\(answer.text), \(state.selected.contains(answer.id) ? "selected" : "not selected")"
            append(.answer(answer.id), label: label, frame: region.frame)
        }
        let total = poll.results == nil ? "Votes unavailable" : "\(poll.totalVotes) \(poll.totalVotes == 1 ? "vote" : "votes")"
        append(.votes, label: "\(total), show voters", frame: layout.votesFrame)
        if !poll.isClosed() {
            if poll.selectedAnswerIDs.isEmpty {
                append(.reveal, label: results ? "Go back to vote" : "Show results", frame: layout.revealFrame)
            }
            if !results || !poll.selectedAnswerIDs.isEmpty {
                append(.submit, label: poll.selectedAnswerIDs.isEmpty ? "Vote" : "Remove Vote", frame: layout.submitFrame,
                       enabled: model?.canUpdatePollVote(on: message, removing: !poll.selectedAnswerIDs.isEmpty) == true
                           && (!state.selected.isEmpty || !poll.selectedAnswerIDs.isEmpty))
            }
        }
    }
}
