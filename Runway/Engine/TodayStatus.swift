import Foundation

/// Today's state uses the daily remainder, including when the period has money left.
enum TodayStatus: Equatable, Sendable {
  case normal
  case nearLimit
  case noAllowance
  case over

  init(_ result: AllowanceResult) {
    if result.remainingTodayCents < 0 {
      self = .over
    } else if result.allowanceTodayCents <= 0 {
      self = .noAllowance
    } else if Decimal(result.remainingTodayCents) < Decimal(result.allowanceTodayCents) / 5 {
      self = .nearLimit
    } else {
      self = .normal
    }
  }

  var title: String {
    switch self {
    case .normal: "On track"
    case .nearLimit: "Near limit"
    case .noAllowance: "No allowance left"
    case .over: "Over budget"
    }
  }

  var symbol: String {
    switch self {
    case .normal: "checkmark.circle"
    case .nearLimit: "exclamationmark.circle"
    case .noAllowance: "minus.circle"
    case .over: "exclamationmark.triangle.fill"
    }
  }
}

/// Uses calendar days rather than a fixed duration, including on DST transition days.
func nextMidnight(after date: Date, calendar: Calendar) -> Date {
  calendar.dateInterval(of: .day, for: date)!.end
}
