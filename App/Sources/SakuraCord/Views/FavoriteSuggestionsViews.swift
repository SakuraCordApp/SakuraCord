import SakuraCordModels
import SwiftUI

/// Discord's Suggested Channels above the Favorites list: each with Add, and
/// one dismiss for all of them.
struct FavoriteSuggestionsSection: View {
    let model: AppModel

    var body: some View {
        let suggestions = model.favorites.suggestions
        if !suggestions.isEmpty {
            Section {
                ForEach(suggestions) { suggestion in
                    FavoriteSuggestionRow(destination: suggestion) { model.addFavoriteSuggestion(suggestion) }
                        .selectionDisabled()
                }
                Divider()
                    .listRowInsets(EdgeInsets())
                    .selectionDisabled()
                    .accessibilityHidden(true)
            } header: {
                HStack {
                    Text("Suggested Channels")
                    Spacer(minLength: 0)
                    HoverCloseButton(
                        help: "Dismiss Suggested Channels",
                        accessibilityIdentifier: "favorites-suggestions-dismiss",
                        diameter: InterfaceScale.metric(22),
                        iconSize: 11,
                        action: model.dismissFavoriteSuggestions
                    )
                }
                // The section header runs 7 pt past the rows; this puts the
                // × glyph on the Add buttons' trailing edge.
                .padding(.trailing, InterfaceScale.metric(7))
                .foregroundStyle(Color.primary.opacity(0.5))
                .interfaceFontOverride(.interface(.subheadline).weight(.bold))
            }
        }
    }
}

private struct FavoriteSuggestionRow: View {
    let destination: ForwardDestination
    let add: () -> Void

    var body: some View {
        HStack(spacing: InterfaceScale.metric(8)) {
            ForwardDestinationAvatar(destination: destination)
            VStack(alignment: .leading, spacing: InterfaceScale.metric(1)) {
                Text(destination.title)
                    .font(.interface(.body).weight(.medium))
                    .lineLimit(1)
                if !destination.detail.isEmpty {
                    Text(destination.detail)
                        .font(.interface(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button("Add", action: add)
                .buttonStyle(.glass)
                .controlSize(.small)
                .accessibilityLabel("Add \(destination.title) to Favorites")
        }
        .padding(.vertical, InterfaceScale.metric(4))
        .accessibilityElement(children: .contain)
    }
}

/// The first-run sidebar under the suggestions: how to add favourites, then,
/// with nothing suggested, a sketch of the list they will fill.
struct FavoritesEmptySidebarHint: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(8)) {
            Text("Fill up your Favorites")
                .font(.interface(.headline))
            Text("Right-click any channel or DM and [add to your Favorites](sakuracord-favorites:add) for quick access.")
                .font(.interface(.callout))
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.openURL, OpenURLAction { _ in
                    model.favorites.isPickerPresented = true
                    return .handled
                })
            if model.favorites.suggestions.isEmpty {
                Divider().padding(.vertical, InterfaceScale.metric(8))
                FavoritesPlaceholderRows()
            }
        }
        .padding(.vertical, InterfaceScale.metric(8))
        .selectionDisabled()
        .listRowBackground(Color.clear)
    }
}

/// Discord's sketch of a filled list: a text channel, a voice channel and a DM.
private struct FavoritesPlaceholderRows: View {
    var body: some View {
        VStack(alignment: .leading, spacing: InterfaceScale.metric(12)) {
            row("number", width: 0.7)
            row("speaker.wave.2.fill", width: 0.5)
            row("bubble.left.fill", width: 0.7)
        }
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
    }

    private func row(_ symbol: String, width: CGFloat) -> some View {
        HStack(spacing: InterfaceScale.metric(8)) {
            Image(systemName: symbol)
                .font(.interface(.caption))
                .frame(width: ChannelSidebarLayoutMetrics.iconWidth)
            GeometryReader { geometry in
                Capsule().frame(width: geometry.size.width * width, height: InterfaceScale.metric(8))
            }
            .frame(height: InterfaceScale.metric(8))
        }
    }
}

/// Discord's empty Favorites view: what it's for, and a way to add the first ones.
struct FavoritesEmptyState: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: InterfaceScale.metric(16)) {
            Image(systemName: "star.fill")
                .font(.interfaceSystem(size: 44, weight: .semibold))
                .foregroundStyle(SakuraCordAccentColor.labelOnFill)
                .frame(width: InterfaceScale.metric(88), height: InterfaceScale.metric(88))
                .background(SakuraCordAccentColor.color.gradient, in: .rect(cornerRadius: InterfaceScale.metric(24)))
                .rotationEffect(.degrees(-8))
                .accessibilityHidden(true)
            VStack(spacing: InterfaceScale.metric(6)) {
                Text("Your favorite conversations, all in one place.")
                    .font(.interface(.title2).weight(.bold))
                Text("Bring your most-used channels and DMs together for quick access.")
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: InterfaceScale.metric(340))
            ModalGlassButton(symbol: "plus", label: "Add to Favorites", primary: true) {
                model.favorites.isPickerPresented = true
            }
            .fixedSize()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
