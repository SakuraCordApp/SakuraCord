import Foundation
import Observation
import SakuraCordModels

/// Popover-owned pages shared by poll voters and reaction details.
@MainActor @Observable
final class MessagePeoplePager<Selection: Hashable> {
    struct Page {
        var users: [User]
        var hasMore: Bool
        var cursor: UserID?
        var count: Int?
    }

    private struct Request {
        var id: UUID
        var count: Int?
        var task: Task<Void, Never>
    }

    var pages: [Selection: Page] = [:]
    var errors: [Selection: String] = [:]
    var revisions: [Selection: UInt64] = [:]
    var generation: UInt64 = 0
    @ObservationIgnored private var requests: [Selection: Request] = [:]

    func invalidate(_ selection: Selection) {
        requests.removeValue(forKey: selection)?.task.cancel()
        pages[selection] = nil
        errors[selection] = nil
        revisions[selection, default: 0] &+= 1
    }

    func reset() {
        generation &+= 1
        for request in requests.values { request.task.cancel() }
        requests = [:]
        pages = [:]
        errors = [:]
        revisions = [:]
    }

    @discardableResult func load(
        _ selection: Selection, count: Int?, after: UserID?,
        isCurrent: @escaping @MainActor () -> Bool,
        fetch: @escaping @MainActor (UserID?) async throws -> MessagePeoplePage
    ) -> Task<Void, Never>? {
        let after = after.flatMap { cursor in pages[selection]?.count == count ? cursor : nil }
        if let request = requests[selection] {
            guard after == nil, request.count != count else { return request.task }
            requests.removeValue(forKey: selection)?.task.cancel()
        }
        if after == nil, let page = pages[selection], page.count == count, errors[selection] == nil { return nil }
        errors[selection] = nil
        if count == 0 {
            pages[selection] = Page(users: [], hasMore: false, cursor: nil, count: 0)
            return nil
        }
        let id = UUID()
        let task = Task { [weak self] in
            defer {
                if self?.requests[selection]?.id == id { self?.requests[selection] = nil }
            }
            do {
                try Task.checkCancellation()
                let result = try await fetch(after)
                guard let self, !Task.isCancelled, self.requests[selection]?.id == id, isCurrent() else { return }
                let existing = after == nil ? [] : self.pages[selection]?.users ?? []
                var seen = Set<UserID>()
                self.pages[selection] = Page(
                    users: (existing + result.users).filter { seen.insert($0.id).inserted },
                    hasMore: result.hasMore && !result.users.isEmpty && result.users.last?.id != after,
                    cursor: result.users.last?.id, count: count
                )
            } catch {
                guard let self, !Task.isCancelled, self.requests[selection]?.id == id, isCurrent() else { return }
                self.errors[selection] = error.localizedDescription
            }
        }
        requests[selection] = Request(id: id, count: count, task: task)
        return task
    }
}
