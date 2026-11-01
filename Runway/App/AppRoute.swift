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

  /// A widget's link goes back to Today, unless a sheet is open: leaving History would close its
  /// editor and lose the draft without asking.
  mutating func open(_ url: URL) {
    guard AppDeepLink(url: url) == .today, !todayPresentsSheet, !historyPresentsSheet else {
      return
    }
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
