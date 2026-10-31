import Foundation

/// Helpers for USD amounts stored as integer cents. Never route money through `Double`.
enum Money {
  static let currencyCode = "USD"

  /// A fixed locale for deterministic output (tests, previews).
  static let fixedLocale = Locale(identifier: "en_US")

  /// Converts cents to an exact decimal dollar amount.
  static func dollars(fromCents cents: Int) -> Decimal {
    Decimal(cents) / 100
  }

  /// Converts a decimal dollar amount to cents, rounding half away from zero.
  static func cents(fromDollars dollars: Decimal) -> Int {
    var scaled = dollars * 100
    var rounded = Decimal()
    NSDecimalRound(&rounded, &scaled, 0, .plain)
    return NSDecimalNumber(decimal: rounded).intValue
  }

  /// Formats cents as USD, e.g. `1234` → `$12.34` in `en_US`.
  static func format(cents: Int, locale: Locale = .autoupdatingCurrent) -> String {
    dollars(fromCents: cents).formatted(.currency(code: currencyCode).locale(locale))
  }

  /// Formats cents as short USD for when the full amount can't fit, e.g. `$12.3M` in `en_US`.
  /// Rounds half away from zero to one decimal, moving up a unit when needed: $999,950 is `$1M`.
  /// Amounts under $1,000 are already short, so they stay exact.
  static func abbreviated(cents: Int, locale: Locale = .autoupdatingCurrent) -> String {
    guard cents.magnitude >= 100_000 else { return format(cents: cents, locale: locale) }
    return dollars(fromCents: cents).formatted(
      .currency(code: currencyCode)
        .notation(.compactName)
        .precision(.fractionLength(0...1))
        .rounded(rule: .toNearestOrAwayFromZero)
        .locale(locale)
    )
  }
}
