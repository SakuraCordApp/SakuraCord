import SwiftUI

@MainActor
final class StablePopoverHostingController<Content: View>: NSHostingController<Content> {
    private let dismiss: () -> Void

    init(rootView: Content, dismiss: @escaping () -> Void) {
        self.dismiss = dismiss
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func cancelOperation(_ sender: Any?) {
        dismiss()
    }
}
