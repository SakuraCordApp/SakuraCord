import SwiftUI

struct ComposerCharacterCounter: View {
    let characterCount: Int
    let premiumType: Int?

    var body: some View {
        let limit = ChatCharacterLimitPolicy.limit(premiumType: premiumType)
        Text("\(characterCount) / \(limit)")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(characterCount > limit ? .red : .secondary)
            .padding(.horizontal, 4)
            .background(.regularMaterial, in: Capsule())
            .accessibilityLabel("\(characterCount) of \(limit) characters")
    }
}
