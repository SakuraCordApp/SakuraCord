import AppKit

@MainActor
final class NativeTimelineCanvasStorage {
    var items: [NativeMessageTimelineItem] = []
    var layouts: [NativeTimelineRowLayout] = []
    var rowHeights: [CGFloat] = []
    var rowOrigins: [CGFloat] = []
    var contentHeight: CGFloat = 0
}

/// The canvas's row layouts, with the row being edited inline laid out
/// around its editor.
@MainActor
struct NativeTimelineCanvasLayouts: @MainActor RandomAccessCollection {
    let storage: NativeTimelineCanvasStorage
    let editing: NativeTimelineEditingSession

    var startIndex: Int { storage.layouts.startIndex }
    var endIndex: Int { storage.layouts.endIndex }

    subscript(index: Int) -> NativeTimelineRowLayout {
        // The edit's row index can trail a storage update until the canvas
        // reconciles it, so the replacement also has to match the message.
        if index == editing.rowIndex, let layout = editing.layout,
           storage.items[index].messageID == editing.messageID {
            return layout
        }
        return storage.layouts[index]
    }
}
