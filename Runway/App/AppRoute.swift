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
