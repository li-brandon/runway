import Foundation
import WidgetKit

/// Shares the app lock setting with widgets, which can't read the app's own defaults.
enum WidgetPrivacy {
  static let appLockEnabledKey = "appLockEnabled"

  static var sharedDefaults: UserDefaults? {
    UserDefaults(suiteName: RunwayModelContainer.appGroupIdentifier)
  }

  /// Whether widgets should treat amounts as private. Without a recorded setting they do, because
  /// the lock may be on: the app hasn't shared it yet, or the App Group can't be reached.
  static func amountsArePrivate(in defaults: UserDefaults?) -> Bool {
    defaults?.object(forKey: appLockEnabledKey) as? Bool ?? true
  }

  /// Records the setting, and refreshes widgets if it changed.
  static func share(appLockEnabled: Bool, in defaults: UserDefaults) {
    guard defaults.object(forKey: appLockEnabledKey) as? Bool != appLockEnabled else { return }
    defaults.set(appLockEnabled, forKey: appLockEnabledKey)
    WidgetCenter.shared.reloadAllTimelines()
  }
}
