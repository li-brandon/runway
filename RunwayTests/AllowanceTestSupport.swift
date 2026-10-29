import Foundation

@testable import Runway

extension Calendar {
  /// A Gregorian calendar in a fixed time zone, so tests don't depend on the machine's settings.
  static func gregorian(_ timeZoneIdentifier: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
    return calendar
  }

  /// A local wall-clock time in this calendar's time zone. Avoid times that DST skips or repeats.
  func date(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int = 0,
    _ minute: Int = 0,
    _ second: Int = 0
  ) -> Date {
    let components = DateComponents(
      year: year,
      month: month,
      day: day,
      hour: hour,
      minute: minute,
      second: second
    )
    return date(from: components)!
  }
}

func expense(_ amountCents: Int, _ date: Date) -> ExpenseSnapshot {
  ExpenseSnapshot(amountCents: amountCents, date: date)
}
