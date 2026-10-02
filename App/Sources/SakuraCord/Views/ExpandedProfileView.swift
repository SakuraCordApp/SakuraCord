import SakuraCordModels
import SwiftUI

struct ExpandedProfileView: View {
    let model: AppModel
    let initialPresentation: ProfilePresentationState
    @State private var selectedGame: ProfileGame?
    @Environment(\.windowModalContext) private var modal

    private var presentation: ProfilePresentationState {
        guard let current = model.liveProfilePresentation(for: .expanded),
              current.id == initialPresentation.id else { return initialPresentation }
        return current
    }

    var body: some View {
        ProfileExpandedSurface(profile: presentation.profile, profileContent: {
            ProfilePresentationContent(presentation: presentation, layout: .expanded, maximumPopoverHeight: 720)
        }, widgets: {
            widgetBoard
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .overlay(alignment: .topTrailing) {
                    HoverCloseButton(help: "Close Profile", accessibilityIdentifier: "expanded-profile-close") { modal?() }
                        .padding(10)
                }
        })
        .environment(\.profileCosmeticPolicy, model.cosmeticPolicy)
        .environment(\.serverTagCardModel, model)
        .windowModalSize(width: 820, height: 720)
        .background(ProfileVerticalScrollInput())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Expanded Profile")
        .windowModal(item: $selectedGame) { game in
            ProfileGameView(model: model, game: game)
        }
    }

    @ViewBuilder
    private var widgetBoard: some View {
        if let profile = presentation.profile, let widgets = profile.widgets, !widgets.isEmpty {
            ProfileWidgetBoardViewport {
                ProfileWidgetsSection(
                        displayName: profile.displayName,
                        widgets: widgets,
                        resources: profile.widgetResources,
                        animates: modal?.isVisible ?? true,
                        openGame: { selectedGame = $0 },
                        connectApplication: profile.widgetResources?.connections == nil ? nil : { configuration in
                            if let url = configuration.connectionURL {
                                _ = MessageLinkActivator.activate(url, model: model, displayedText: url.absoluteString)
                            }
                        }
                    )
                    .padding(.top, 12)
            }
        } else if presentation.isLoading {
            ProgressView("Loading widgets…").padding(48)
        } else if let error = presentation.errorMessage {
            ContentUnavailableView {
                Label("Couldn't Load Widgets", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            }
        } else {
            ContentUnavailableView("No Widgets", systemImage: "square.grid.2x2", description: Text("This person hasn't added any widgets to their profile."))
        }
    }
}

struct ExpandedProfilePresentationModifier: ViewModifier {
    @Bindable var model: AppModel

    func body(content: Content) -> some View {
        content.windowModal(item: Binding(
            get: { model.expandedProfilePresentation },
            set: { if $0 == nil { model.dismissExpandedProfile() } }
        )) { presentation in
            ExpandedProfileView(model: model, initialPresentation: presentation)
        }
    }
}
