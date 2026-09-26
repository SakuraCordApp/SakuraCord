import AppKit
import Foundation
import Observation
import SakuraCordModels
import SwiftUI

struct EmojiDocumentRowView: View {
    let row: EmojiDocumentRow
    let skinTone: NativeEmojiSkinTone
    let interaction: EmojiPickerInteractionModel
    let isFavorite: (EmojiPickerItem) -> Bool
    let choose: (EmojiPickerCell, Bool) -> Void
    let toggleFavorite: (EmojiPickerItem) -> Void
    let retry: (GuildID) -> Void
    var lockReason: (EmojiPickerItem) -> String? = { _ in nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch row.content {
            case let .header(title, count):
                EmojiPickerHeader(title: title, count: count, horizontalInset: 6)
                    .padding(.top, 8)
            case let .emojis(cells):
                nativeRow(cells)
                .frame(height: EmojiPickerGridMetrics.cellSize)
                .frame(maxWidth: .infinity)
            case let .empty(message):
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 38)
            case .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading server emojis…")
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 42)
            case let .failure(guildID, details):
                HStack(spacing: 8) {
                    Image(systemName: "wifi.exclamationmark")
                    Text("Couldn’t load these emojis.")
                    Button("Retry") { retry(guildID) }
                        .buttonStyle(.link)
                        .focusable(false)
                }
                .help(details)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 42)
            }
        }
    }

    func makeNativeView(reusing reused: NSView?, environment: EnvironmentValues) -> NSView? {
        guard case .emojis(let cells) = row.content else { return nil }
        let view = reused as? NativeEmojiPickerRowView ?? NativeEmojiPickerRowView()
        view.configure(nativeRow(cells), colorScheme: environment.colorScheme,
            animates: !environment.accessibilityReduceMotion && environment.accessibilityPlayAnimatedImages,
            isEnabled: environment.isEnabled)
        return view
    }

    private func nativeRow(_ cells: [EmojiPickerCell]) -> NativeEmojiPickerRow {
        NativeEmojiPickerRow(
            cells: cells, skinTone: skinTone,
            selectedCellID: interaction.selectedCellID,
            isFavorite: isFavorite, choose: choose,
            hover: interaction.select, toggleFavorite: toggleFavorite,
            lockReason: lockReason
        )
    }
}

struct EmojiHoverPreviewBar: View {
    let interaction: EmojiPickerInteractionModel
    let skinTone: NativeEmojiSkinTone

    var body: some View {
        HStack(spacing: 6) {
            interaction.item.preview(skinTone: skinTone, dimension: 28, nativeFontSize: 24)
                .frame(width: 30, height: 30, alignment: .center)
            Text(interaction.item.shortcode)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 38, alignment: .center)
        .accessibilityElement(children: .combine)
    }
}

struct EmojiNativeJumpButton: View {
    let isSelected: Bool
    let jump: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: jump) {
            SakuraCordSystemSymbol.emojiFaceGrinningImage
                .symbolVariant(.none)
                .font(.system(size: 17))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .frame(width: 30, height: 30)
                .background {
                    Circle().fill(
                        isSelected
                            ? Color.primary.opacity(0.13)
                            : Color.primary.opacity(isHovering ? 0.09 : 0.05)
                    )
                }
        }
        .buttonStyle(.plain)
        .focusable(false)
        .frame(width: EmojiSidebarLayout.railWidth, height: 38)
        .contentShape(Rectangle())
        .onModalHover { isHovering = $0 }
        .help("Jump to native emojis")
        .accessibilityLabel("Jump to native emojis")
    }
}

enum EmojiSidebarLayout {
    static let railWidth = PickerSectionRailLayout.width
}

struct EmojiDocumentSidebar: View {
    let guilds: [Guild]
    let showsFavorites: Bool
    let showsFrequentlyUsed: Bool
    let visibleSection: EmojiDocumentSection
    @Binding var nativeCategoriesAreVisible: Bool
    let showsNativeJumpButton: Bool
    let jump: (EmojiDocumentSection) -> Void
    let jumpToNative: () -> Void
    @State private var scrollPosition = ScrollPosition(idType: String.self)

    var body: some View {
        VStack(spacing: 0) {
            PickerSectionRail(scrollPosition: $scrollPosition) {
                if showsFavorites {
                    PickerSectionBookmark(
                        section: .favorites, visibleSection: visibleSection,
                        help: "Favorites", jump: jump
                    ) { Image(systemName: "star.fill") }
                }
                if showsFrequentlyUsed {
                    PickerSectionBookmark(
                        section: .frequent, visibleSection: visibleSection,
                        help: "Frequently Used", jump: jump
                    ) { Image(systemName: "clock.fill") }
                }

                if !guilds.isEmpty {
                    if showsFavorites || showsFrequentlyUsed {
                        Divider()
                            .frame(width: 28)
                            .padding(.vertical, 2)
                    }

                    ForEach(guilds) { guild in
                        PickerSectionBookmark(
                            section: .guild(guild.id), visibleSection: visibleSection,
                            help: guild.name, jump: jump
                        ) { PickerGuildBookmarkIcon(guild: guild) }
                    }
                }

                VStack(spacing: 2) {
                    if showsFavorites || showsFrequentlyUsed || !guilds.isEmpty {
                        Divider()
                            .frame(width: 28)
                            .padding(.vertical, 2)
                    }

                    ForEach(NativeEmojiCategory.allCases) { category in
                        PickerSectionBookmark(
                            section: .native(category), visibleSection: visibleSection,
                            help: category.title, jump: jump
                        ) {
                            Text(category.symbol)
                                .font(.system(size: 18))
                                .frame(width: 28, height: 28, alignment: .center)
                        }
                    }
                }
                .onAppear { nativeCategoriesAreVisible = true }
                .onDisappear { nativeCategoriesAreVisible = false }
            }

            if showsNativeJumpButton {
                Divider()
                EmojiNativeJumpButton(
                    isSelected: visibleSection.isNative,
                    jump: {
                        scrollPosition.scrollTo(edge: .bottom)
                        jumpToNative()
                    }
                )
            }
        }
        .frame(width: EmojiSidebarLayout.railWidth)
    }
}

extension EmojiPickerItem {
    var discordKeys: Set<String> {
        switch self {
        case let .native(emoji): emoji.discordKeys
        case let .custom(emoji): [emoji.id]
        }
    }
}
