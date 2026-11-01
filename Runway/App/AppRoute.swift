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

  /// A widget's link only has to bring the app forward, since the root is already Today. It must
  /// not rebuild: that would close an open editor and lose its draft without asking.
  mutating func open(_ url: URL) {
    switch AppDeepLink(url: url) {
    case .today, nil:
      break
    }
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
