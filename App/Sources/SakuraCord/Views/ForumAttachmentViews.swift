import SwiftUI

struct ForumActionErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: InterfaceScale.metric(10)) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.interface(.callout))
                .lineLimit(2)
            Spacer(minLength: InterfaceScale.metric(8))
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .help("Dismiss error")
        }
        .padding(.horizontal, InterfaceScale.metric(14))
        .padding(.vertical, InterfaceScale.metric(9))
        // Glass of its own: the forum header has no backdrop, and posts
        // scroll beneath the banner.
        .glassEffect(
            .regular.tint(Color.red.opacity(0.2)),
            in: RoundedRectangle(cornerRadius: InterfaceScale.metric(14), style: .continuous)
        )
        .padding(.horizontal, InterfaceScale.metric(14))
        .padding(.bottom, InterfaceScale.metric(8))
        .accessibilityElement(children: .contain)
    }
}

struct ForumEmptyState: View {
    let title: String
    let description: String
    let systemImage: String

    var body: some View {
        VStack(spacing: InterfaceScale.metric(10)) {
            Image(systemName: systemImage)
                .font(.interfaceSystem(size: 34, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.interface(.headline))
            Text(description)
                .font(.interface(.callout))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, InterfaceScale.metric(24))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
