import Foundation

/// Which screen the app shows at its root.
enum AppRoute: Equatable, Sendable {
  /// Today with an initial budget setup sheet. Dismissing it reveals the empty state.
  case setup
  /// The main screen. Its Settings button reopens setup.
  case main

  init(hasBudget: Bool) {
    self = hasBudget ? .main : .setup
  }
}

/// When `RootView` rebuilds everything below it, closing any open sheets.
struct RootViewState: Equatable, Sendable {
  private(set) var dataGeneration = 0

  /// After an import or reset. Views may hold models that no longer exist, and reading those can
  /// crash.
  mutating func dataDidReplace() {
    dataGeneration += 1
  }
}

/// What Today's stack shows. `ContentView` owns it below `RootView`'s `id`, so an import or reset
/// starts it over along with the sheets it describes.
struct TodayNavigation: Equatable, Sendable {
  var showsHistory = false
  var todayPresentsSheet = false
  var historyPresentsSheet = false
  /// When History's pending undo runs out, or `nil` if it has none.
  var historyUndoExpiresAt: Date?

  /// A widget's link goes back to Today, unless a sheet is open: leaving History would close its
  /// editor and lose the draft without asking. It also stays on History while Undo can still
  /// restore a delete, since the undo lives and dies with that screen. The deadline is compared
  /// with `now` because an undo that ran out while the app was suspended may not have cleared yet.
  mutating func open(_ url: URL, now: Date) {
    guard AppDeepLink(url: url) == .today, !todayPresentsSheet, !historyPresentsSheet else {
      return
    }
    if let historyUndoExpiresAt, now < historyUndoExpiresAt { return }
    showsHistory = false
  }
}

/// Presentation state shared by the empty-state action and its setup sheet.
struct TodayEmptyState {
  var showsSetup: Bool

  init(opensSetup: Bool = true) {
    showsSetup = opensSetup
  }

  mutating func openSetup() {
    showsSetup = true
  }
}
