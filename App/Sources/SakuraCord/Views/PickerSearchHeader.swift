import SwiftUI

/// Shared search chrome for floating pickers; the caller owns text editing and keyboard behavior.
struct PickerSearchHeader<Input: View>: View {
    @Binding var text: String
    let focus: () -> Void
    @ViewBuilder let input: () -> Input

    var body: some View {
        HStack(spacing: ChatChromeMetrics.pickerSearchHeaderSpacing) {
            Image(systemName: "magnifyingglass")
                .font(.interfaceSystem(size: ChatChromeMetrics.pickerSearchHeaderIconSize, weight: .medium))
                .foregroundStyle(.secondary)
            input().frame(maxWidth: .infinity)
            Button {
                text = ""
                focus()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear search")
            .accessibilityLabel("Clear search")
            .opacity(text.isEmpty ? 0 : 1)
            .disabled(text.isEmpty)
            .accessibilityHidden(text.isEmpty)
        }
        .padding(.horizontal, ChatChromeMetrics.pickerSearchHeaderInset)
        .frame(height: ChatChromeMetrics.pickerSearchHeaderHeight)
        .contentShape(Rectangle())
        .onTapGesture(perform: focus)
        .accessibilityIdentifier("picker-search")
    }
}
