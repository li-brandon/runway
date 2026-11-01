import Foundation
import SwiftUI

/// Lets `RunwayTests` reach what SwiftUI only offers a finger or the system: a swipe action, a
/// banner's button, and an opened link. Views register the same functions their controls call, and
/// clear them when those controls leave the screen, so a hook that isn't `nil` also means its
/// control is showing. The app never sets one, so these stay `nil` outside tests.
@MainActor
final class TodayViewHooks {
  /// What the History toolbar button does.
  var showHistory: (@MainActor () -> Void)?
  /// What `onOpenURL` does on Today.
  var openURL: (@MainActor (URL) -> Void)?
  /// What an expense row's Delete does. Set while History is on screen.
  var deleteExpense: (@MainActor (Expense) -> Void)?
  /// What the undo banner's button does. Set while History shows the banner.
  var undoDelete: (@MainActor () -> Void)?
}

extension EnvironmentValues {
  @Entry var todayViewHooks: TodayViewHooks? = nil
}
