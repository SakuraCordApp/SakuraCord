import SwiftUI

struct MediaPreviewActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.interface(.callout).weight(.semibold))
                .padding(.horizontal, InterfaceScale.metric(16))
                .frame(height: InterfaceScale.metric(42))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .glassEffect(
            .regular.tint(SakuraCordAccentColor.color).interactive(),
            in: Capsule()
        )
    }
}
