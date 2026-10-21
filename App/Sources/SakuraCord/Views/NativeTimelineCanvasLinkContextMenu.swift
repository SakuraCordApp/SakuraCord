import AppKit

extension NativeTimelineCanvasView {
    func prependTextLinkActions(
        to menu: NSMenu,
        row: MessageRowPresentation,
        index: Int,
        localPoint: CGPoint
    ) {
        let layout = layouts[index]
        let isConcealed = layout.componentLayouts.contains { component in
            component.containers.contains { container in
                container.isSpoiler && container.frame.contains(localPoint)
                    && !spoilerRevealStore.isMediaRevealed(
                        NativeTimelineComponentRevealKey(
                            messageID: row.message.id,
                            componentID: container.componentID
                        )
                    )
            }
        }
        guard !isConcealed,
              let text = textPointerHit(in: layout, point: localPoint),
              text.hit.mention?.isInteractive != true,
              let url = text.hit.url,
              url.scheme != "sakuracord-action"
        else { return }
        if let spoilerRange = text.hit.spoilerRange {
            guard let key = textSpoilerRevealKey(
                itemIdentifier: items[index].identifier,
                region: text.region,
                rangeLocation: spoilerRange.location
            ), spoilerRevealStore.isTextRevealed(key) else { return }
        }
        let open = textLinkOpenWithMenu(url: url, displayedText: text.hit.displayedText)
        let copy = actionItem("Copy Link", systemImage: "link") {
            Self.copyText(url.absoluteString)
        }
        menu.insertItem(.separator(), at: 0)
        menu.insertItem(copy, at: 0)
        menu.insertItem(open, at: 0)
    }

    private func textLinkOpenWithMenu(url: URL, displayedText: String?) -> NSMenuItem {
        let workspace = NSWorkspace.shared
        let defaultApplication = workspace.urlForApplication(toOpen: url)
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for application in workspace.urlsForApplications(toOpen: url) {
            let name = FileManager.default.displayName(atPath: application.path)
            let title = application == defaultApplication ? "\(name) (Default)" : name
            let item = actionItem(title, systemImage: "app") { [weak self] in
                self?.openTextLink(url, displayedText: displayedText, application: application)
            }
            let icon = workspace.icon(forFile: application.path)
            icon.size = NSSize(width: 16, height: 16)
            ContextMenuItemSupport.configure(item, image: icon)
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        ContextMenuItemSupport.configure(item, title: "Open With", systemImage: "arrow.up.forward.app")
        item.submenu = submenu
        item.isEnabled = !submenu.items.isEmpty
        return item
    }

    private func openTextLink(_ url: URL, displayedText: String?, application: URL) {
        MessageLinkActivator.openExternal(url, model: model, displayedText: displayedText) { [weak self] assessment in
            ExternalLinkConfirmationPresenter.shared.present(
                assessment,
                opener: { confirmedURL in
                    Task { @MainActor [weak self] in
                        do {
                            try await MessageLinkActivator.openInApplication(
                                confirmedURL,
                                applicationURL: application
                            )
                        } catch {
                            self?.presentActionError(error)
                        }
                    }
                }
            )
        }
    }
}
