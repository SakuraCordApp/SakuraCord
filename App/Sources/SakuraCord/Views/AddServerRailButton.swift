import SwiftUI

struct AddServerRailButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: InterfaceScale.metric(4)) {
                ServerRailSelectionIndicator(isSelected: false, isHovering: isHovering, hasNotification: false)
                Image(systemName: "plus")
                    .font(.interfaceSystem(size: 22, weight: .medium))
                    .frame(width: InterfaceScale.metric(44), height: InterfaceScale.metric(44))
                    .foregroundStyle(.green)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: InterfaceScale.metric(13)))
                    .frame(width: InterfaceScale.metric(46), height: InterfaceScale.metric(46))
            }
            .frame(width: ChatChromeMetrics.serverRailWidth, height: InterfaceScale.metric(46), alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(ServerRailButtonStyle())
        .anchorPreference(key: ServerRailHoverPreferenceKey.self, value: .bounds) { bounds in
            isHovering ? ServerRailHoverItem(name: "Add Server", bounds: bounds) : nil
        }
        .onModalHover { isHovering = $0 }
        .animation(.snappy(duration: 0.18), value: isHovering)
        .help("Add Server")
        .accessibilityLabel("Add Server")
        .accessibilityIdentifier("add-server")
    }
}
