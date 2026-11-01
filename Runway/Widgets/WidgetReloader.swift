import Combine
import Foundation
import SwiftData
import UIKit
import WidgetKit

/// The one place the app decides when widgets refresh. Every expense, extra money, bill, and budget
/// change, import, and reset ends in a save, and every save posts `ModelContext.didSave`, whichever
/// screen or context made it, so those paths don't call this themselves.
@MainActor
enum WidgetReloader {
  /// Fires on any save, and when the clock or time zone changes.
  static func triggers(
    in center: NotificationCenter = .default
  ) -> some Publisher<Notification, Never> {
    Publishers.MergeMany(
      center.publisher(for: ModelContext.didSave),
      center.publisher(for: UIApplication.significantTimeChangeNotification),
      center.publisher(for: NSNotification.Name.NSSystemTimeZoneDidChange)
    )
  }

  static func reload() {
    WidgetCenter.shared.reloadAllTimelines()
  }
}
