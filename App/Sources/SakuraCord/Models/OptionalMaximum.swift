nonisolated func maximum<T: Comparable>(_ lhs: T?, _ rhs: T?) -> T? {
    switch (lhs, rhs) {
    case (.some(let lhs), .some(let rhs)): max(lhs, rhs)
    case (.some(let lhs), .none): lhs
    case (.none, .some(let rhs)): rhs
    case (.none, .none): nil
    }
}
