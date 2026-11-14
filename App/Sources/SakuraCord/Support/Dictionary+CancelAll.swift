extension Dictionary {
    /// Cancels every task and empties the dictionary.
    mutating func cancelAll<Success: Sendable, Failure: Error>() where Value == Task<Success, Failure> {
        values.forEach { $0.cancel() }
        removeAll()
    }
}
