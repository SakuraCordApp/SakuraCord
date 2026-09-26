import SakuraCordModels
import SwiftUI

struct OnboardingQuestion: View {
    let model: AppModel
    let guildID: GuildID
    let prompt: GuildOnboardingPrompt
    var large = false
    private var entry: GuildOnboardingStore.Entry { model.onboarding.entries[guildID] ?? .init() }
    private var selected: [GuildOnboardingOption] { prompt.options.filter { entry.responses.contains($0.id) } }
    private var usesMenu: Bool { prompt.type == 1 || prompt.options.count >= 13 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(prompt.title + (!large && prompt.required ? " *" : ""))
                    .font(large ? .largeTitle.weight(.semibold) : .headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if ![0, 1].contains(prompt.type) {
                Label("This question uses an unsupported answer type.", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            } else if prompt.options.isEmpty {
                Text("This question has no available answers. Refresh after the server updates it.").foregroundStyle(.secondary)
            } else if usesMenu {
                menu
            } else {
                ViewThatFits(in: .horizontal) {
                    optionGrid(columns: 2).frame(minWidth: large ? 520 : 430)
                    optionGrid(columns: 1)
                }
            }
            if !prompt.singleSelect {
                Text("Choose all that apply.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .disabled((entry.initial && entry.isSaving) || entry.needsRefresh)
    }

    private func optionGrid(columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 12) {
            ForEach(prompt.options) { option in optionButton(option, descriptions: true) }
        }
    }

    private var menuOptions: [SelectionFieldOption<String>] {
        prompt.options.map { option in
            let leading: SelectionFieldLeading
            if let url = option.emoji?.url {
                leading = .remoteImage(url: url, fallback: option.title, shape: .roundedRectangle)
            } else if let name = option.emoji?.name, !name.isEmpty {
                leading = .text(name)
            } else {
                leading = .none
            }
            return SelectionFieldOption(id: option.id, title: option.title, leading: leading)
        }
    }

    private var menu: some View {
        SelectionField(
            selection: Binding(
                get: { selected.map(\.id) },
                set: { model.setOnboardingOptions(Set($0), prompt: prompt, guildID: guildID) }
            ),
            mode: prompt.singleSelect ? .single : .multiple(),
            source: .local(options: menuOptions),
            configuration: .init(placeholder: "Select…", searchPlaceholder: "Search options"),
            accessibilityIdentifier: "onboarding-selection-\(prompt.id)"
        )
        .id(menuOptions)
        .accessibilityLabel(prompt.title)
    }

    private func optionButton(_ option: GuildOnboardingOption, descriptions: Bool) -> some View {
        OnboardingOptionRow(option: option, selected: entry.responses.contains(option.id), descriptions: descriptions) {
            model.selectOnboardingOption(option, prompt: prompt, guildID: guildID)
        }
    }
}

private struct OnboardingOptionRow: View {
    let option: GuildOnboardingOption
    let selected: Bool
    let descriptions: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                OnboardingEmoji(emoji: option.emoji)
                VStack(alignment: .leading, spacing: 4) {
                    Text(option.title).font(.body.weight(.medium))
                    if descriptions, let description = option.description, !description.isEmpty {
                        Text(description).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? SakuraCordAccentColor.color : .secondary.opacity(0.5))
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(ConcentricRectangle(cornerRadius: 16))
            .background(selected ? SakuraCordAccentColor.color.opacity(0.13) : Color.primary.opacity(hovered ? 0.09 : 0.04), in: ConcentricRectangle(cornerRadius: 16))
            .overlay { ConcentricRectangle(cornerRadius: 16).stroke(selected ? SakuraCordAccentColor.color.opacity(0.8) : Color.primary.opacity(0.08)) }
        }
        .buttonStyle(.plain).onHover { hovered = $0 }
        .accessibilityLabel(option.title).accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct OnboardingEmoji: View {
    let emoji: GuildOnboardingOption.Emoji?
    var body: some View {
        if let url = emoji?.url {
            AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { Color.clear }
                .frame(width: 24, height: 24).accessibilityHidden(true)
        } else if let name = emoji?.name, !name.isEmpty {
            Text(name).font(.title3).accessibilityHidden(true)
        }
    }
}
