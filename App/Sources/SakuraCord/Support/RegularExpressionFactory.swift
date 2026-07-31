import Foundation

nonisolated enum RegularExpressionFactory {
    static func make(
        _ pattern: String,
        options: NSRegularExpression.Options = []
    ) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            preconditionFailure("Invalid checked-in regular expression: \(error)")
        }
    }
}
