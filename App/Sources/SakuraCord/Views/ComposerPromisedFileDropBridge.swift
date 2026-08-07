import AppKit
import SwiftUI

struct ComposerPromisedFileDropBridge: NSViewRepresentable {
    var isEnabled: Bool
    let targetChanged: (_ isTargeted: Bool, _ location: CGPoint, _ isInstant: Bool) -> Void
    let receiveFiles: (
        _ batch: ComposerPromisedFileBatch,
        _ location: CGPoint,
        _ isInstant: Bool
    ) -> Void

    func makeNSView(context _: Context) -> ComposerPromisedFileDropView {
        ComposerPromisedFileDropView(
            isEnabled: isEnabled,
            targetChanged: targetChanged,
            receiveFiles: receiveFiles
        )
    }

    func updateNSView(_ view: ComposerPromisedFileDropView, context _: Context) {
        view.isEnabled = isEnabled
        view.targetChanged = targetChanged
        view.receiveFiles = receiveFiles
    }
}

final class ComposerPromisedFileDropView: NSView {
    var isEnabled: Bool
    var targetChanged: (Bool, CGPoint, Bool) -> Void
    var receiveFiles: (ComposerPromisedFileBatch, CGPoint, Bool) -> Void

    init(
        isEnabled: Bool,
        targetChanged: @escaping (Bool, CGPoint, Bool) -> Void,
        receiveFiles: @escaping (ComposerPromisedFileBatch, CGPoint, Bool) -> Void
    ) {
        self.isEnabled = isEnabled
        self.targetChanged = targetChanged
        self.receiveFiles = receiveFiles
        super.init(frame: .zero)
        registerForDraggedTypes(
            NSFilePromiseReceiver.readableDraggedTypes.map {
                NSPasteboard.PasteboardType($0)
            }
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateTarget(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateTarget(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        targetChanged(false, .zero, false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let receivers = promisedFileReceivers(from: sender.draggingPasteboard)
        guard isEnabled, !receivers.isEmpty,
              let directory = try? Self.makeReceivingDirectory()
        else { return false }

        let location = convert(sender.draggingLocation, from: nil)
        let isInstant = NSEvent.modifierFlags.contains(.shift)
        // Each receiver represents one promised file. `fileTypes` lists the
        // representations that file can provide; it is not a callback count.
        let collector = ComposerPromisedFileCollector(
            expectedCount: receivers.count,
            directory: directory
        ) { [receiveFiles] batch in
            receiveFiles(batch, location, isInstant)
        }
        for receiver in receivers {
            receiver.receivePromisedFiles(
                atDestination: directory,
                options: [:],
                operationQueue: .main
            ) { url, error in
                collector.receive(url: url, error: error)
            }
        }
        targetChanged(false, .zero, false)
        return true
    }

    static func makeReceivingDirectory(fileManager: FileManager = .default) throws -> URL {
        try ComposerPromisedFileStorage.makeReceivingDirectory(
            fileManager: fileManager
        )
    }

    private func updateTarget(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let location = convert(sender.draggingLocation, from: nil)
        let isInstant = NSEvent.modifierFlags.contains(.shift)
        let acceptsDrop = isEnabled
            && !promisedFileReceivers(from: sender.draggingPasteboard).isEmpty
        targetChanged(acceptsDrop, location, isInstant)
        return acceptsDrop ? .copy : []
    }

    private func promisedFileReceivers(from pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
        pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self],
            options: nil
        ) as? [NSFilePromiseReceiver] ?? []
    }
}

struct ComposerAttachmentEditorTarget: Identifiable {
    let id: UUID
}

@MainActor
final class ComposerPromisedFileCollector {
    private var remainingCount: Int
    private var receivedURLs: [URL] = []
    private let directory: URL
    private let completion: (ComposerPromisedFileBatch) -> Void

    init(
        expectedCount: Int,
        directory: URL,
        completion: @escaping (ComposerPromisedFileBatch) -> Void
    ) {
        remainingCount = expectedCount
        self.directory = directory
        self.completion = completion
    }

    func receive(url: URL, error: Error?) {
        if error == nil {
            receivedURLs.append(url)
        }
        remainingCount -= 1
        if remainingCount == 0 {
            let batch = ComposerPromisedFileBatch(
                directory: directory,
                urls: receivedURLs
            )
            if receivedURLs.isEmpty {
                batch.discard()
            }
            completion(batch)
        }
    }
}
