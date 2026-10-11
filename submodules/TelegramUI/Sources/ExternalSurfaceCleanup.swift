import Foundation
import CoreSpotlight
import Intents
import TelegramCore
import WidgetItems
import NotificationsPresentationData

/// Dual PIN v1 (plan §7, docs/dual-pin/EXTERNAL.md): the app publishes nothing to widgets,
/// Spotlight or Siri, and the notification extensions are not built. Removes what an earlier
/// build of this fork left there; each step touches only this app's own data and is harmless
/// when there is nothing to remove.
func removeExternalSurfaceData(rootPath: String, accountManagerBasePath: String) {
    // Presentation data the widget and the notification content extension read.
    let _ = try? FileManager.default.removeItem(atPath: widgetPresentationDataPath(rootPath: rootPath))
    let _ = try? FileManager.default.removeItem(atPath: notificationsPresentationDataPath(rootPath: rootPath))
    // Spotlight: this app's index and the contact photos kept for it (`SpotlightIndexStorage`).
    CSSearchableIndex.default().deleteAllSearchableItems(completionHandler: { error in
        if let error {
            Logger.shared.log("ExternalSurfaceCleanup", "Spotlight index not cleared: \(error.localizedDescription)")
        }
    })
    let _ = try? FileManager.default.removeItem(atPath: accountManagerBasePath + "/spotlight")
    // Siri: every interaction this app donated.
    INInteraction.deleteAll(completion: { error in
        if let error {
            Logger.shared.log("ExternalSurfaceCleanup", "Siri interactions not deleted: \(error.localizedDescription)")
        }
    })
}
