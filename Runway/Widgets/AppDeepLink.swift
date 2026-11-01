import Foundation

/// The app's URL scheme, which widgets open when tapped.
enum AppDeepLink: Equatable, Sendable {
  case today

  static let todayURL = URL(string: "runway://today")!

  init?(url: URL) {
    guard url.scheme?.lowercased() == "runway", url.host()?.lowercased() == "today" else {
      return nil
    }
    self = .today
  }
}
