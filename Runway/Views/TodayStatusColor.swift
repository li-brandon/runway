import SwiftUI

extension TodayStatus {
  /// The color of the amount left to spend today, on Today and in widgets.
  var color: Color {
    switch self {
    case .normal: .primary
    case .nearLimit, .noAllowance: .orange
    case .over: .red
    }
  }
}
