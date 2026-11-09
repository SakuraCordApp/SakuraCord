import AppKit
import Foundation

// TEMPORARY EXPERIMENT (do not merge): records why a pending timeline
// layout preparation is cancelled or discarded.
extension NativeMessageTimelineCoordinator {
    func experimentLog(_ reason: String, parent newParent: NativeMessageTimelineView, width: CGFloat) {
        guard let preparation = layoutPreparation else { return }
        let fields: [String] = [
            "rows=\(preparation.rowsRevision)/\(newParent.rowsRevision)",
            "pres=\(preparation.presentationRevision)/\(newParent.presentationRevision)",
            "font=\(preparation.fontRevision)/\(ProfileNameFontCache.revision)",
            "invite=\(preparation.inviteRevision)/\(newParent.model.serverInvites.revision)",
            "day=\(preparation.timestampDay == Calendar.autoupdatingCurrent.startOfDay(for: .now))",
            "coordDay=\(timestampDay == Calendar.autoupdatingCurrent.startOfDay(for: .now))",
            "width=\(preparation.width)/\(width)/layout \(layoutWidth)",
            "pendingWidth=\(String(describing: pendingLayoutWidth))",
            "model=\(newParent.model === parent.model)",
            "conv=\(newParent.conversation == parent.conversation)",
            "scrollReq=\(newParent.scrollRequest == parent.scrollRequest)",
            "rowCount=\(rowCount)",
            "journal=\(String(describing: newParent.rowsUpdateJournal.latestRevision))/\(newParent.rowsRevision)",
            "ignored=\(newParent.model.ignoredUsers.ignoredUserIDs.count)/\(newParent.model.ignoredUsers.blockedUserIDs.count)",
        ]
        let stack = Thread.callStackSymbols.prefix(8).joined(separator: " | ")
        let line = "FLAKYDIAG \(reason) " + fields.joined(separator: " ") + " stack: " + stack + "\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
