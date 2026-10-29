/// Which screen the app shows at its root.
enum AppRoute: Equatable, Sendable {
  /// Budget setup. Shown until a budget has been saved, so a first launch lands here.
  case setup
  /// The main screen. Its Settings button reopens setup.
  case main

  init(hasBudget: Bool) {
    self = hasBudget ? .main : .setup
  }
}
