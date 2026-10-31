import SwiftUI

/// Limits on shrinking text to fit. Text should wrap rather than shrink past this floor, so it
/// stays readable at the largest accessibility sizes.
enum TextScaling {
  static let minimumFactor: CGFloat = 0.7
}

/// The sizes an amount tries, largest first. A number split across lines is misread, so unlike
/// other text an amount never wraps: past the scale floor it drops to smaller text styles, and
/// past the smallest it's abbreviated. See `AmountText`.
enum AmountStyle: Hashable {
  case scaled(CGFloat)
  case textStyle(Font.TextStyle)
  /// A text style in the default design, for amounts outside "Left to spend today".
  case plain(Font.TextStyle, Font.Weight)

  /// The largest the amount's full size can get, however large the Dynamic Type setting.
  static let maximumSize: CGFloat = 96
  /// Every candidate stays on one line.
  static let lineLimit = 1

  /// "Left to spend today".
  static var heroSteps: [AmountStyle] {
    [
      .scaled(1),
      .scaled(0.85),
      .scaled(TextScaling.minimumFactor),
      .textStyle(.title),
      .textStyle(.title3),
      .textStyle(.headline),
    ]
  }

  /// The spending summary's total.
  static var summarySteps: [AmountStyle] {
    [
      .plain(.largeTitle, .bold),
      .plain(.title, .bold),
      .plain(.title3, .bold),
      .plain(.headline, .bold),
    ]
  }

  /// An amount in a list row.
  static var rowSteps: [AmountStyle] {
    [
      .plain(.body, .semibold),
      .plain(.subheadline, .semibold),
      .plain(.caption, .semibold),
    ]
  }

  func font(fullSize: CGFloat) -> Font {
    switch self {
    case .scaled(let factor):
      return .system(size: fullSize * factor, weight: .bold, design: .rounded)
    case .textStyle(let style):
      return .system(style, design: .rounded, weight: .bold)
    case .plain(let style, let weight):
      return .system(style, weight: weight)
    }
  }
}
