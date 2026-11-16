import DiscordProtocol
import SwiftUI

enum ActivityStackPreset: String, CaseIterable, Identifiable {
    case gamesFirst
    case musicFirst
    case streamingFirst
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gamesFirst: return "Games First (Default)"
        case .musicFirst: return "Music First"
        case .streamingFirst: return "Streaming First"
        case .custom: return "Custom Order"
        }
    }

    var order: [ActivityCategory]? {
        switch self {
        case .gamesFirst: return [.games, .streaming, .music, .other]
        case .musicFirst: return [.music, .games, .streaming, .other]
        case .streamingFirst: return [.streaming, .games, .music, .other]
        case .custom: return nil
        }
    }

    static func matching(order: [ActivityCategory]) -> ActivityStackPreset {
        let normalized = ActivityCategory.normalizedOrder(order)
        if normalized == ActivityStackPreset.gamesFirst.order {
            return .gamesFirst
        } else if normalized == ActivityStackPreset.musicFirst.order {
            return .musicFirst
        } else if normalized == ActivityStackPreset.streamingFirst.order {
            return .streamingFirst
        }
        return .custom
    }
}

struct ActivityStackPriorityCard: View {
    @Binding var activityStackOrder: [ActivityCategory]
    let state: SettingsViewState

    private var currentPreset: ActivityStackPreset {
        ActivityStackPreset.matching(order: activityStackOrder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(10)) {
            HStack(spacing: InterfaceScale.metric(8)) {
                Text("Activity Stack Priority", bundle: #bundle)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Picker("Priority Preset", selection: Binding(
                    get: { currentPreset },
                    set: { newPreset in
                        if let newOrder = newPreset.order {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                activityStackOrder = newOrder
                            }
                        }
                    }
                )) {
                    ForEach(ActivityStackPreset.allCases) { preset in
                        if preset != .custom || currentPreset == .custom {
                            Text(preset.title).tag(preset)
                        }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityLabel("Activity stack priority preset")
            }

            Text(
                "Drag and arrange categories horizontally to customize priority. Top priority (leftmost) is displayed as your primary activity.",
                bundle: #bundle
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: InterfaceScale.metric(8)) {
                    ForEach(Array(activityStackOrder.enumerated()), id: \.element) { index, category in
                        ActivityStackBlockTile(
                            index: index,
                            category: category,
                            activityStackOrder: $activityStackOrder
                        )

                        if index < activityStackOrder.count - 1 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: InterfaceScale.metric(10), weight: .bold))
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .padding(InterfaceScale.metric(6))
            }
            .padding(InterfaceScale.metric(4))
            .background(
                RoundedRectangle(cornerRadius: InterfaceScale.metric(10), style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
        }
        .padding(.vertical, InterfaceScale.metric(4))
        .settingsControlAnchor(.activityStackOrder, state: state)
    }
}

struct ActivityStackBlockTile: View {
    let index: Int
    let category: ActivityCategory
    @Binding var activityStackOrder: [ActivityCategory]
    @State private var isTargeted = false

    private var isTopPriority: Bool {
        index == 0
    }

    var body: some View {
        HStack(spacing: InterfaceScale.metric(8)) {
            Text("\(index + 1)")
                .font(.caption2.monospacedDigit().bold())
                .foregroundStyle(isTopPriority ? SakuraCordAccentColor.color : .secondary)
                .frame(width: InterfaceScale.metric(18), height: InterfaceScale.metric(18))
                .background(
                    Circle()
                        .fill(isTopPriority ? SakuraCordAccentColor.color.opacity(0.18) : Color.primary.opacity(0.08))
                )

            Image(systemName: category.iconName)
                .font(.callout)
                .foregroundStyle(isTopPriority ? SakuraCordAccentColor.color : .primary)

            VStack(alignment: .leading, spacing: 0) {
                Text(category.displayName)
                    .font(.caption.weight(isTopPriority ? .semibold : .medium))
                if isTopPriority {
                    Text("Top Priority", bundle: #bundle)
                        .font(.system(size: InterfaceScale.metric(9), weight: .bold))
                        .foregroundStyle(SakuraCordAccentColor.color)
                }
            }
        }
        .padding(.horizontal, InterfaceScale.metric(12))
        .padding(.vertical, InterfaceScale.metric(8))
        .background(
            RoundedRectangle(cornerRadius: InterfaceScale.metric(8), style: .continuous)
                .fill(
                    isTargeted
                        ? SakuraCordAccentColor.color.opacity(0.16)
                        : (isTopPriority ? SakuraCordAccentColor.color.opacity(0.10) : Color.primary.opacity(0.06))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: InterfaceScale.metric(8), style: .continuous)
                .strokeBorder(
                    isTargeted
                        ? SakuraCordAccentColor.color
                        : (isTopPriority ? SakuraCordAccentColor.color.opacity(0.40) : Color.primary.opacity(0.10)),
                    lineWidth: isTargeted || isTopPriority ? 1.5 : 1
                )
        )
        .draggable(category.rawValue)
        .dropDestination(for: String.self) { items, _ in
            guard let draggedRaw = items.first,
                  let draggedCategory = ActivityCategory(rawValue: draggedRaw),
                  let fromIndex = activityStackOrder.firstIndex(of: draggedCategory),
                  let toIndex = activityStackOrder.firstIndex(of: category),
                  fromIndex != toIndex else {
                return false
            }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                let item = activityStackOrder.remove(at: fromIndex)
                activityStackOrder.insert(item, at: toIndex)
            }
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
        .contextMenu {
            Button("Make Top Priority") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    guard let currIdx = activityStackOrder.firstIndex(of: category), currIdx > 0 else { return }
                    let item = activityStackOrder.remove(at: currIdx)
                    activityStackOrder.insert(item, at: 0)
                }
            }
            if index > 0 {
                Button("Move Left") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        guard let currIdx = activityStackOrder.firstIndex(of: category), currIdx > 0 else { return }
                        activityStackOrder.swapAt(currIdx, currIdx - 1)
                    }
                }
            }
            if index < activityStackOrder.count - 1 {
                Button("Move Right") {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        guard let currIdx = activityStackOrder.firstIndex(of: category),
                              currIdx < activityStackOrder.count - 1 else { return }
                        activityStackOrder.swapAt(currIdx, currIdx + 1)
                    }
                }
            }
        }
        .help("Drag to rearrange priority, or right-click for quick actions")
    }
}
