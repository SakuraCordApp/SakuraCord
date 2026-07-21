import SwiftUI

public struct MessageBodyView: View {
    private let content: String
    private let font: Font?

    public init(content: String, font: Font? = nil) {
        self.content = content
        self.font = font
    }

    public var body: some View {
        Text(MarkdownRenderCache.shared.attributedString(for: content))
            .font(font)
            .lineSpacing(1)
            .textSelection(.enabled)
    }
}

@MainActor
private final class MarkdownRenderCache {
    static let shared = MarkdownRenderCache()

    private let values = NSCache<NSString, AttributedStringBox>()

    private init() {
        values.countLimit = 1000
        values.totalCostLimit = 8 * 1024 * 1024
    }

    func attributedString(for source: String) -> AttributedString {
        let key = source as NSString
        if let cached = values.object(forKey: key) {
            return cached.value
        }
        let value = DiscordMarkdown.attributed(source)
        values.setObject(AttributedStringBox(value), forKey: key, cost: source.utf8.count)
        return value
    }
}

private final class AttributedStringBox: NSObject {
    let value: AttributedString

    init(_ value: AttributedString) {
        self.value = value
    }
}
