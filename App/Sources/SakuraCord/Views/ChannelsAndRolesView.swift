import AppKit
import SakuraCordModels
import SwiftUI

private enum ChannelsAndRolesTab: Hashable {
  case customize
  case browse
}

private enum ChannelPreviewSplitPresentation {
  static let autosaveName = "SakuraCord.ChannelPreviewSplit"
}

private enum ChannelPreviewMembershipPillMetrics {
  static let minimumPreviewWidth: CGFloat = 500
  static let topContentInset: CGFloat = 46
}

nonisolated enum BrowseChannelPresentation {
  static func individualToggleIsEnabled(isCategoryFollowed: Bool) -> Bool {
    !isCategoryFollowed
  }

  static func activityText(since date: Date, now: Date = .now) -> String {
    let elapsed = max(0, now.timeIntervalSince(date))
    let days = Int(elapsed / 86_400)
    if days >= 1 {
      return "Active \(days) \(days == 1 ? "day" : "days") ago"
    }
    let hours = Int(elapsed / 3_600)
    if hours >= 1 {
      return "Active \(hours) \(hours == 1 ? "hour" : "hours") ago"
    }
    let minutes = max(1, Int(elapsed / 60))
    return "Active \(minutes) \(minutes == 1 ? "minute" : "minutes") ago"
  }
}

struct ChannelsAndRolesView: View {
  let model: AppModel
  let guildID: GuildID
  @State private var selection = ChannelsAndRolesTab.customize

  var body: some View {
    Group {
      if let channel = previewChannel {
        HSplitView {
          primaryContent
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            .background {
              SplitViewAutosaveBridge(
                autosaveName: ChannelPreviewSplitPresentation.autosaveName
              )
              .frame(width: 0, height: 0)
            }
          ChannelsAndRolesChannelPreview(model: model, channel: channel)
            .frame(
              minWidth: ChannelPreviewMembershipPillMetrics.minimumPreviewWidth,
              idealWidth: ChannelPreviewMembershipPillMetrics.minimumPreviewWidth,
              maxWidth: .infinity
            )
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
      } else {
        primaryContent
      }
    }
    .frame(minWidth: 660, minHeight: 520)
    .animation(.snappy(duration: 0.22), value: model.channelsAndRolesPreviewChannelID)
    .onChange(of: selection) { _, tab in
      if tab != .browse { model.closeChannelsAndRolesPreview() }
    }
    .onDisappear { model.closeChannelsAndRolesPreview() }
  }

  private var primaryContent: some View {
    Group {
      if model.onboardingLoadingGuildIDs.contains(guildID) {
        ProgressView("Loading Channels & Roles…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let configuration = model.onboardingConfigurationsByGuild[guildID] {
        VStack(spacing: 0) {
          ChannelsAndRolesTabBar(
            selection: $selection,
            browseCount: model.accessibleChannelsForBrowse(guildID: guildID).count
          )
          switch selection {
          case .customize:
            CustomizeRolesView(
              model: model,
              guildID: guildID,
              configuration: configuration
            )
          case .browse:
            BrowseChannelsView(model: model, guildID: guildID)
          }
        }
      } else {
        ChannelsAndRolesErrorView(
          message: model.onboardingErrorsByGuild[guildID]
            ?? "Channels & Roles is unavailable for this server.",
          retry: { Task { await model.loadOnboardingIfNeeded(for: guildID) } }
        )
      }
    }
    .overlay(alignment: .top) {
      Divider().offset(y: 46)
    }
  }

  private var previewChannel: Channel? {
    guard let channelID = model.channelsAndRolesPreviewChannelID else { return nil }
    return model.snapshot?.channels.first { $0.id == channelID }
  }
}

private struct SplitViewAutosaveBridge: NSViewRepresentable {
  let autosaveName: NSSplitView.AutosaveName

  func makeNSView(context: Context) -> SplitViewAutosaveProbe {
    SplitViewAutosaveProbe(autosaveName: autosaveName)
  }

  func updateNSView(_ nsView: SplitViewAutosaveProbe, context: Context) {
    nsView.autosaveName = autosaveName
    nsView.installAutosaveName()
  }
}

private final class SplitViewAutosaveProbe: NSView {
  var autosaveName: NSSplitView.AutosaveName

  init(autosaveName: NSSplitView.AutosaveName) {
    self.autosaveName = autosaveName
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    installAutosaveName()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    installAutosaveName()
  }

  func installAutosaveName() {
    Task { @MainActor [weak self] in
      await Task.yield()
      guard let self else { return }
      var candidate = superview
      while let view = candidate {
        if let splitView = view as? NSSplitView {
          if splitView.autosaveName != autosaveName {
            splitView.autosaveName = autosaveName
          }
          return
        }
        candidate = view.superview
      }
    }
  }
}

private struct ChannelsAndRolesTabBar: View {
  @Binding var selection: ChannelsAndRolesTab
  let browseCount: Int

  var body: some View {
    HStack(spacing: 0) {
      GlassEffectContainer(spacing: 8) {
        HStack(spacing: 8) {
          tabButton("Customize", tab: .customize)
          tabButton("Browse Channels", count: browseCount, tab: .browse)
        }
      }
      Spacer()
    }
    .padding(.horizontal, 24)
    .frame(height: 46)
  }

  private func tabButton(
    _ title: String,
    count: Int? = nil,
    tab: ChannelsAndRolesTab
  ) -> some View {
    Button {
      withAnimation(.snappy(duration: 0.2)) { selection = tab }
    } label: {
      HStack(spacing: 7) {
        Text(title)
        if let count {
          Text(count, format: .number)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
        }
      }
      .font(.callout.weight(.semibold))
      .foregroundStyle(selection == tab ? Color.primary : Color.secondary)
      .contentShape(.rect)
    }
    .buttonStyle(
      .glass(
        selection == tab
          ? .regular.tint(Color.accentColor.opacity(0.18)).interactive()
          : .regular.interactive()
      )
    )
    .buttonBorderShape(.capsule)
    .controlSize(.regular)
    .accessibilityAddTraits(selection == tab ? .isSelected : [])
  }
}

private struct CustomizeRolesView: View {
  let model: AppModel
  let guildID: GuildID
  let configuration: GuildOnboardingConfiguration

  var body: some View {
    GeometryReader { proxy in
      ScrollView {
        if proxy.size.width >= 900 {
          HStack(alignment: .top, spacing: 28) {
            questions.frame(maxWidth: .infinity)
            MemberProfileSummary(model: model, guildID: guildID, configuration: configuration)
              .frame(width: 240)
          }
        } else {
          VStack(alignment: .leading, spacing: 28) {
            questions
            MemberProfileSummary(model: model, guildID: guildID, configuration: configuration)
          }
        }
      }
      .scrollIndicators(.visible)
    }
  }

  private var questions: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Customization Questions")
          .font(.title3.weight(.semibold))
        Text("Answer questions to get access to more channels and roles.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      let requirements = configuration.connections + configuration.additionalConnections
      if !requirements.isEmpty {
        LinkedAccountRequirementsView(requirements: requirements)
      }
      ForEach(configuration.prompts) { prompt in
        OnboardingPromptSection(
          model: model,
          guildID: guildID,
          prompt: prompt,
          selectedOptionIDs: Set(configuration.selectedOptionIDs),
          submitsImmediately: false
        )
      }
    }
    .padding(24)
  }
}

private struct MemberProfileSummary: View {
  let model: AppModel
  let guildID: GuildID
  let configuration: GuildOnboardingConfiguration

  private var user: User? { model.snapshot?.currentUser }

  private var member: Member? {
    guard let userID = user?.id else { return nil }
    return model.membersByGuildID[guildID]?[userID] ?? model.membersByID[userID]
  }

  private var roles: [GuildRole] {
    let currentRoleIDs = member.map { Set($0.roleIDs) }
      ?? model.currentUserRoleIDsByGuild[guildID]
      ?? []
    let roleIDs = configuration.projectedRoleIDs(currentRoleIDs: currentRoleIDs)
    var catalogue = model.guildRolesByGuildID[guildID] ?? model.guildRoles
    for role in member?.roles ?? [] where !catalogue.contains(where: { $0.id == role.id }) {
      catalogue.append(role)
    }
    return
      catalogue
      .filter { roleIDs.contains($0.id) && $0.name != "@everyone" }
      .sorted { $0.position > $1.position }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 2) {
        Text("My Profile")
          .font(.title3.weight(.semibold))
        Text("This is how you'll look to others.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      VStack(spacing: 10) {
        AvatarView(
          name: user?.displayName ?? "You",
          url: member?.guildAvatarURL ?? user?.avatarURL,
          size: 78,
          animates: false
        )
        Text(user?.displayName ?? "You")
          .font(.title2.weight(.semibold))
        if let customStatus = member?.customStatus, !customStatus.isEmpty {
          ProfileStatusTextView(
            source: customStatus,
            isExpanded: true,
            fontSize: 13,
            usesSecondaryColor: true
          )
          .frame(maxWidth: 210, minHeight: 32)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity)
      Divider()
      Text("ROLES")
        .font(.caption2.weight(.bold))
        .foregroundStyle(.secondary)
      ProfileRolesSection(roles: roles, isAlwaysExpanded: true)
        .padding(.horizontal, -16)
      if roles.isEmpty {
        Text("No displayed roles")
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.top, 24)
    .padding(.trailing, 24)
    .padding(.bottom, 24)
  }
}

struct GuildOnboardingSheet: View {
  let model: AppModel
  let guildID: GuildID

  var body: some View {
    if let presentation = model.initialOnboardingPresentation,
      presentation.guildID == guildID
    {
      VStack(alignment: .leading, spacing: 0) {
        GuildOnboardingHeader(guildName: presentation.guildName)
        Divider()
        OnboardingPromptList(
          model: model,
          guildID: guildID,
          prompts: presentation.configuration.prompts,
          connectionRequirements: presentation.configuration.connections
            + presentation.configuration.additionalConnections,
          selectedOptionIDs: Set(presentation.configuration.selectedOptionIDs),
          includesOnlyJoinPrompts: true
        )
        Divider()
        GuildOnboardingFooter(
          isSubmitting: presentation.isSubmitting,
          isWaiting: presentation.isWaitingForConfirmation,
          errorMessage: presentation.errorMessage,
          submit: { Task { await model.submitInitialOnboarding(guildID: guildID) } }
        )
      }
      .frame(minWidth: 580, idealWidth: 680, minHeight: 520, idealHeight: 620)
    } else {
      ProgressView("Waiting for Discord…")
        .frame(width: 420, height: 240)
    }
  }
}

private struct GuildOnboardingHeader: View {
  let guildName: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Welcome to \(guildName)")
        .font(.largeTitle.bold())
      Text(
        "Choose the roles and channels that fit you. You can change these later in Channels & Roles."
      )
      .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(24)
  }
}

private struct OnboardingPromptList: View {
  let model: AppModel
  let guildID: GuildID
  let prompts: [GuildOnboardingPrompt]
  let connectionRequirements: [GuildOnboardingConnectionRequirement]
  let selectedOptionIDs: Set<String>
  let includesOnlyJoinPrompts: Bool

  private var visiblePrompts: [GuildOnboardingPrompt] {
    includesOnlyJoinPrompts ? prompts.filter(\.isInOnboarding) : prompts
  }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 18) {
        if !connectionRequirements.isEmpty {
          LinkedAccountRequirementsView(requirements: connectionRequirements)
        }
        ForEach(visiblePrompts) { prompt in
          OnboardingPromptSection(
            model: model,
            guildID: guildID,
            prompt: prompt,
            selectedOptionIDs: selectedOptionIDs,
            submitsImmediately: includesOnlyJoinPrompts
          )
        }
      }
      .padding(24)
    }
  }
}

private struct LinkedAccountRequirementsView: View {
  let requirements: [GuildOnboardingConnectionRequirement]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Linked accounts")
        .font(.headline)
      Text("Complete these account requirements in Discord, then return here.")
        .font(.caption)
        .foregroundStyle(.secondary)
      ForEach(Array(requirements.enumerated()), id: \.offset) { _, requirement in
        Button {
          guard let url = URL(string: "discord://-/settings/connections") else { return }
          NSWorkspace.shared.open(url)
        } label: {
          Label(requirement.name ?? "Manage linked account", systemImage: "arrow.up.right.square")
        }
      }
    }
    .padding(16)
    .glassEffect(.regular, in: .rect(cornerRadius: 14))
  }
}

private struct OnboardingPromptSection: View {
  let model: AppModel
  let guildID: GuildID
  let prompt: GuildOnboardingPrompt
  let selectedOptionIDs: Set<String>
  let submitsImmediately: Bool

  private var columns: [GridItem] {
    Array(
      repeating: GridItem(.flexible(minimum: 190), spacing: 10),
      count: 3
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Text(prompt.title)
          .font(.headline)
        if prompt.isRequired {
          Text("*")
            .foregroundStyle(.red)
            .accessibilityLabel("Required")
        }
      }
      if prompt.usesCompactOptionList {
        OnboardingDropdownPrompt(
          prompt: prompt,
          selectedOptionIDs: selectedOptionIDs,
          toggle: toggle
        )
      } else {
        GlassEffectContainer(spacing: 10) {
          LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(prompt.options) { option in
              OnboardingOptionCard(
                option: option,
                isSelected: selectedOptionIDs.contains(option.id),
                isSingleSelect: prompt.isSingleSelect,
                toggle: { toggle(option) }
              )
            }
          }
        }
      }
      Text(prompt.isSingleSelect ? "Choose one." : "Choose all that apply.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(18)
    .background(.background.opacity(0.35), in: .rect(cornerRadius: 16))
    .overlay {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(.separator, lineWidth: 1)
    }
  }

  private func toggle(_ option: GuildOnboardingOption) {
    model.updateOnboardingSelection(
      guildID: guildID,
      promptID: prompt.id,
      optionID: option.id,
      isSelected: !selectedOptionIDs.contains(option.id),
      submitsImmediately: submitsImmediately
    )
  }
}

private struct OnboardingDropdownPrompt: View {
  let prompt: GuildOnboardingPrompt
  let selectedOptionIDs: Set<String>
  let toggle: (GuildOnboardingOption) -> Void
  @State private var isPresented = false
  @State private var searchText = ""

  private var selectedOptions: [GuildOnboardingOption] {
    prompt.options.filter { selectedOptionIDs.contains($0.id) }
  }

  private var filteredOptions: [GuildOnboardingOption] {
    guard !searchText.isEmpty else { return prompt.options }
    return prompt.options.filter {
      $0.title.localizedCaseInsensitiveContains(searchText)
        || $0.description?.localizedCaseInsensitiveContains(searchText) == true
    }
  }

  private var showsSearch: Bool { prompt.options.count >= 20 }

  private var chooserHeight: CGFloat {
    min(CGFloat(filteredOptions.count) * 50 + (showsSearch ? 48 : 0) + 24, 372)
  }

  var body: some View {
    selectionField
      .popover(isPresented: $isPresented, arrowEdge: .top) {
        optionChooser
      }
    .accessibilityLabel(prompt.title)
    .accessibilityValue(
      selectedOptions.isEmpty
        ? "No selection"
        : selectedOptions.map(\.title).joined(separator: ", ")
    )
  }

  private var selectionField: some View {
    ZStack {
      Button {
        isPresented.toggle()
      } label: {
        Color.clear
          .frame(maxWidth: .infinity, minHeight: 42)
          .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityHidden(true)

      HStack(spacing: 8) {
        if selectedOptions.isEmpty {
          Text("Select…")
            .foregroundStyle(.secondary)
            .allowsHitTesting(false)
        } else {
          ForEach(Array(selectedOptions.prefix(3))) { option in
            OnboardingSelectedOptionChip(
              option: option,
              open: { isPresented = true },
              remove: { toggle(option) }
            )
          }
          if selectedOptions.count > 3 {
            Button {
              isPresented = true
            } label: {
              Text("+\(selectedOptions.count - 3)")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .contentShape(.rect(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .background(.quaternary, in: .rect(cornerRadius: 7))
            .accessibilityLabel("Show all selected options")
          }
        }
        Spacer(minLength: 8)
        Image(systemName: isPresented ? "chevron.up" : "chevron.down")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .allowsHitTesting(false)
      }
      .padding(.leading, 8)
      .padding(.trailing, 12)
    }
    .frame(maxWidth: .infinity, minHeight: 42)
    .glassEffect(
      .regular.interactive(),
      in: .rect(cornerRadius: 10)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
    }
  }

  private var optionChooser: some View {
    GlassEffectContainer(spacing: 8) {
      VStack(spacing: 6) {
        if showsSearch {
          HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
              .foregroundStyle(.secondary)
            TextField("Search options", text: $searchText)
              .textFieldStyle(.plain)
            if !searchText.isEmpty {
              Button {
                searchText = ""
              } label: {
                Image(systemName: "xmark.circle.fill")
                  .foregroundStyle(.secondary)
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Clear search")
            }
          }
          .padding(.horizontal, 10)
          .frame(height: 36)
          .glassEffect(.clear.interactive(), in: .rect(cornerRadius: 9))
        }

        ScrollView {
          LazyVStack(spacing: 2) {
            ForEach(filteredOptions) { option in
              OnboardingPopoverOptionRow(
                option: option,
                isSelected: selectedOptionIDs.contains(option.id),
                isSingleSelect: prompt.isSingleSelect
              ) {
                let wasSelected = selectedOptionIDs.contains(option.id)
                toggle(option)
                if prompt.isSingleSelect, !wasSelected {
                  isPresented = false
                }
              }
            }
          }
        }
        .scrollIndicators(.visible)
      }
      .padding(5)
      .frame(width: 408, height: chooserHeight - 12)
      .glassEffect(
        .regular,
        in: ConcentricRectangle(cornerRadius: 16, style: .continuous)
      )
      .containerShape(.rect(cornerRadius: 16, style: .continuous))
    }
    .padding(6)
    .frame(width: 420, height: chooserHeight)
    .presentationBackground(.clear)
    .onExitCommand { isPresented = false }
    .onDisappear { searchText = "" }
  }
}

private struct OnboardingSelectedOptionChip: View {
  let option: GuildOnboardingOption
  let open: () -> Void
  let remove: () -> Void
  @State private var removeIsHovering = false

  var body: some View {
    HStack(spacing: 0) {
      Button(action: open) {
        HStack(spacing: 5) {
          OnboardingOptionEmoji(emoji: option.emoji, size: 16)
          Text(option.title)
            .lineLimit(1)
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 28)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)

      Button(action: remove) {
        Image(systemName: "xmark")
          .font(.caption2.weight(.bold))
          .frame(width: 22, height: 22)
          .background(
            removeIsHovering ? Color.primary.opacity(0.12) : .clear,
            in: .circle
          )
          .scaleEffect(removeIsHovering ? 1.08 : 1)
          .contentShape(.circle)
      }
      .buttonStyle(OnboardingChipRemoveButtonStyle())
      .padding(.trailing, 3)
      .onHover { removeIsHovering = $0 }
      .animation(.snappy(duration: 0.16), value: removeIsHovering)
      .accessibilityLabel("Remove \(option.title)")
    }
    .background(.quaternary, in: .rect(cornerRadius: 7))
  }
}

private struct OnboardingChipRemoveButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.86 : 1)
      .opacity(configuration.isPressed ? 0.72 : 1)
      .animation(.snappy(duration: 0.12), value: configuration.isPressed)
  }
}

private struct OnboardingPopoverOptionRow: View {
  let option: GuildOnboardingOption
  let isSelected: Bool
  let isSingleSelect: Bool
  let select: () -> Void
  @State private var isHovering = false

  var body: some View {
    Button(action: select) {
      HStack(spacing: 10) {
        OnboardingOptionEmoji(emoji: option.emoji, size: 22)
        VStack(alignment: .leading, spacing: 2) {
          Text(option.title)
            .font(.body.weight(.medium))
          if let description = option.description, !description.isEmpty {
            Text(description)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        Spacer(minLength: 8)
        Image(
          systemName: isSelected
            ? (isSingleSelect ? "checkmark.circle.fill" : "checkmark.square.fill")
            : (isSingleSelect ? "circle" : "square")
        )
        .font(.title3)
        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
      }
      .padding(.horizontal, 10)
      .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
      .contentShape(.rect(cornerRadius: 9))
    }
    .buttonStyle(.plain)
    .background(
      isHovering ? Color.primary.opacity(0.08) : .clear,
      in: .rect(cornerRadius: 9)
    )
    .onHover { isHovering = $0 }
    .accessibilityValue(isSelected ? "Selected" : "Not selected")
  }
}

private struct OnboardingOptionCard: View {
  let option: GuildOnboardingOption
  let isSelected: Bool
  let isSingleSelect: Bool
  let toggle: () -> Void

  var body: some View {
    Button(action: toggle) {
      HStack(spacing: 11) {
        OnboardingOptionEmoji(emoji: option.emoji, size: 24)
        VStack(alignment: .leading, spacing: 3) {
          Text(option.title)
            .font(.body.weight(.medium))
          if let description = option.description, !description.isEmpty {
            Text(description)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
        }
        Spacer(minLength: 4)
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
      }
      .frame(maxWidth: .infinity, minHeight: 52, maxHeight: 52, alignment: .leading)
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .glassEffect(
      .regular.tint(isSelected ? Color.accentColor.opacity(0.18) : .clear).interactive(),
      in: .rect(cornerRadius: 12)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(
          isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
          lineWidth: isSelected ? 1.5 : 1
        )
    }
    .accessibilityValue(isSelected ? "Selected" : "Not selected")
    .accessibilityHint(isSingleSelect ? "Selects one answer" : "Toggles this answer")
  }
}

private struct OnboardingOptionEmoji: View {
  let emoji: GuildOnboardingEmoji?
  let size: CGFloat

  var body: some View {
    Group {
      if let emoji, let url = emoji.imageURL(size: 64) {
        AnimatedRemoteImage(
          url: url,
          fallbackSystemImage: "face.smiling",
          maximumPixelDimension: 128
        )
      } else if let name = emoji?.name, !name.isEmpty {
        Text(name)
          .font(.system(size: size * 0.86))
          .lineLimit(1)
      } else {
        Color.clear
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

private struct GuildOnboardingFooter: View {
  let isSubmitting: Bool
  let isWaiting: Bool
  let errorMessage: String?
  let submit: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      if let errorMessage {
        Text(errorMessage).font(.caption).foregroundStyle(.red)
      } else if isWaiting {
        Label("Waiting for Discord to confirm your membership…", systemImage: "clock")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if isSubmitting || isWaiting { ProgressView().controlSize(.small) }
      Button("Finish", action: submit)
        .buttonStyle(.glassProminent)
        .disabled(isSubmitting || isWaiting)
        .keyboardShortcut(.defaultAction)
    }
    .padding(20)
  }
}

private struct BrowseChannelsView: View {
  let model: AppModel
  let guildID: GuildID
  @State private var searchText = ""

  private var groups: [ChannelGroup] {
    ChannelGroup.make(from: model.accessibleChannelsForBrowse(guildID: guildID))
      .compactMap { group in
        guard !searchText.isEmpty else { return group }
        var filtered = group
        if group.name?.localizedStandardContains(searchText) == true { return filtered }
        filtered.channels = group.channels.filter {
          $0.name.localizedStandardContains(searchText)
            || $0.topic?.localizedStandardContains(searchText) == true
        }
        return filtered.channels.isEmpty ? nil : filtered
      }
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 9) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField("Search Channels", text: $searchText)
          .textFieldStyle(.plain)
      }
      .padding(.horizontal, 12)
      .frame(height: 38)
      .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 10))
      .padding(.horizontal, 24)
      .padding(.vertical, 16)

      ScrollView {
        LazyVStack(alignment: .leading, spacing: 22) {
          ForEach(groups) { group in
            BrowseChannelGroup(model: model, guildID: guildID, group: group)
          }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
      }
      .overlay {
        if groups.isEmpty { ContentUnavailableView.search(text: searchText) }
      }
    }
  }
}

private struct BrowseChannelGroup: View {
  let model: AppModel
  let guildID: GuildID
  let group: ChannelGroup

  private var isCategoryFollowed: Bool {
    guard let categoryID = group.categoryID else { return false }
    return model.isCategoryOptedIn(guildID: guildID, categoryID: categoryID)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(group.name ?? "Channels")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        if let categoryID = group.categoryID {
          Toggle(
            "Follow Category",
            isOn: Binding(
              get: { model.isCategoryOptedIn(guildID: guildID, categoryID: categoryID) },
              set: { value in
                Task {
                  await model.setCategoryOptIn(
                    value, guildID: guildID, categoryID: categoryID
                  )
                }
              }
            )
          )
          .toggleStyle(.switch)
          .controlSize(.small)
        }
      }
      VStack(spacing: 0) {
        ForEach(Array(group.channels.enumerated()), id: \.element.id) { index, channel in
          BrowseChannelRow(
            model: model,
            channel: channel,
            isCategoryFollowed: isCategoryFollowed,
            roundsTopCorners: index == group.channels.startIndex,
            roundsBottomCorners: index == group.channels.index(before: group.channels.endIndex)
          )
          if index < group.channels.count - 1 { Divider() }
        }
      }
      .background(.background.opacity(0.3), in: .rect(cornerRadius: 12))
      .overlay {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(.separator, lineWidth: 1)
      }
    }
  }
}

private struct BrowseChannelRow: View {
  let model: AppModel
  let channel: Channel
  let isCategoryFollowed: Bool
  let roundsTopCorners: Bool
  let roundsBottomCorners: Bool
  @State private var isHovering = false

  private var isInherited: Bool { model.isChannelInheritedFromOptedInCategory(channel) }

  private var supportsPreview: Bool {
    channel.kind == .text || channel.kind == .announcement
  }

  private var recentActivityDate: Date? {
    guard let date = channel.lastMessageID?.createdAt,
          date > Calendar.current.date(byAdding: .year, value: -1, to: .now) ?? .distantPast
    else { return nil }
    return date
  }

  private var rowShape: UnevenRoundedRectangle {
    UnevenRoundedRectangle(
      topLeadingRadius: roundsTopCorners ? 12 : 0,
      bottomLeadingRadius: roundsBottomCorners ? 12 : 0,
      bottomTrailingRadius: roundsBottomCorners ? 12 : 0,
      topTrailingRadius: roundsTopCorners ? 12 : 0,
      style: .continuous
    )
  }

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      HStack(alignment: .top, spacing: 8) {
        Image(
          systemName: ChannelIconPresentation.systemImage(
            for: channel, isHidden: false, rulesChannelID: nil
          )
        )
        .foregroundStyle(.secondary)
        .frame(width: 16)
        VStack(alignment: .leading, spacing: 4) {
          Text(channel.name)
            .font(.body.weight(.medium))
          HStack(spacing: 7) {
            if let date = recentActivityDate {
              Text(BrowseChannelPresentation.activityText(since: date))
            }
            if let topic = channel.topic, !topic.isEmpty {
              if recentActivityDate != nil { Text("•") }
              Text(topic).lineLimit(1)
            }
            if isInherited {
              Text("• Included by category")
            }
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 8)
      if isHovering, supportsPreview {
        Button("View") {
          model.openChannelsAndRolesPreview(channel)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .transition(.opacity)
      }
      Toggle(
        "Follow \(channel.name)",
        isOn: Binding(
          get: { model.isChannelOptedIn(channel) },
          set: { value in Task { await model.setChannelOptIn(value, channel: channel) } }
        )
      )
      .labelsHidden()
      .toggleStyle(.checkbox)
      .disabled(!BrowseChannelPresentation.individualToggleIsEnabled(
        isCategoryFollowed: isCategoryFollowed
      ))
    }
    .contentShape(.rect)
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background {
      rowShape.fill(isHovering ? Color.primary.opacity(0.07) : .clear)
    }
    .clipShape(rowShape)
    .onHover { isHovering = $0 }
    .animation(.easeOut(duration: 0.12), value: isHovering)
    .accessibilityHint(
      isCategoryFollowed
        ? "Included because the category is followed" : "Shows or hides this channel in the sidebar"
    )
  }
}

private struct ChannelsAndRolesChannelPreview: View {
  let model: AppModel
  let channel: Channel

  var body: some View {
    SupplementaryConversationPane(maximumWidth: .infinity) {
      if !model.isChannelOptedIn(channel) {
        ChatDetailView(
          model: model,
          topContentInset: ChannelPreviewMembershipPillMetrics.topContentInset
        )
          .overlay(alignment: .top) {
            GlassEffectContainer(spacing: 8) {
              membershipPill
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .zIndex(1)
          }
      } else {
        VStack(spacing: 0) {
          Color.clear
            .frame(height: 46)

          ChatDetailView(model: model)
        }
        .frame(maxHeight: .infinity)
      }
    }
  }

  private var membershipPill: some View {
    HStack(spacing: 10) {
      Text("This channel is not on your channel list.")
        .font(.callout)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
      Spacer(minLength: 8)
      Button("Add to Channel List") {
        Task { await model.setChannelOptIn(true, channel: channel) }
      }
      .buttonStyle(.glassProminent)
      .buttonBorderShape(.capsule)
      .controlSize(.small)
    }
    .padding(.leading, 14)
    .padding(.trailing, 6)
    .padding(.vertical, 5)
    .glassEffect(.regular, in: Capsule())
  }
}

private struct ChannelsAndRolesErrorView: View {
  let message: String
  let retry: () -> Void

  var body: some View {
    ContentUnavailableView {
      Label("Channels & Roles Unavailable", systemImage: "exclamationmark.triangle")
    } description: {
      Text(message)
    } actions: {
      Button("Try Again", action: retry)
    }
  }
}
