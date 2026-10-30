import SwiftUI

/// Limits on shrinking text to fit. Text should wrap rather than shrink past this floor, so it
/// stays readable at the largest accessibility sizes.
enum TextScaling {
  static let minimumFactor: CGFloat = 0.7
}

/// The sizes "Left to spend today" tries, largest first. A number split across lines is misread,
/// so unlike other text the amount never wraps: past the scale floor it drops to smaller text
/// styles instead.
enum RemainingAmountStyle: Hashable {
  case scaled(CGFloat)
  case textStyle(Font.TextStyle)

  /// The largest the amount's full size can get, however large the Dynamic Type setting.
  static let maximumSize: CGFloat = 96
  /// Every candidate stays on one line.
  static let lineLimit = 1

  /// The sizes to use when the amount fits at full width without shrinking.
  static var steps: [RemainingAmountStyle] {
    [
      .scaled(1),
      .scaled(0.85),
      .scaled(TextScaling.minimumFactor),
      .textStyle(.title),
      .textStyle(.title3),
      .textStyle(.headline),
    ]
  }

  /// Used when no step fits. Shrinks to the scale floor, and only truncates past that.
  static var lastResort: RemainingAmountStyle { .textStyle(.headline) }

  func font(fullSize: CGFloat) -> Font {
    switch self {
    case .scaled(let factor):
      return .system(size: fullSize * factor, weight: .bold, design: .rounded)
    case .textStyle(let style):
      return .system(style, design: .rounded, weight: .bold)
    }
  }
}
