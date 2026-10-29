import Foundation
import Testing

@testable import Runway

struct MoneyTests {
  @Test(
    "Formats cents as USD in en_US",
    arguments: zip(
      [0, 5, 1_234, -1_234, 100_000, 123_456_789_012],
      ["$0.00", "$0.05", "$12.34", "-$12.34", "$1,000.00", "$1,234,567,890.12"]
    )
  )
  func formatsUSD(cents: Int, expected: String) {
    #expect(Money.format(cents: cents, locale: Money.fixedLocale) == expected)
  }

  @Test("Cents convert to exact decimal dollars")
  func dollarsFromCents() throws {
    #expect(try Money.dollars(fromCents: 1_234) == decimal("12.34"))
    #expect(try Money.dollars(fromCents: -1) == decimal("-0.01"))
    #expect(Money.dollars(fromCents: 0) == 0)
  }

  @Test("Dollars convert to cents, rounding half away from zero")
  func centsFromDollars() throws {
    #expect(try Money.cents(fromDollars: decimal("12.34")) == 1_234)
    #expect(try Money.cents(fromDollars: decimal("12.344")) == 1_234)
    #expect(try Money.cents(fromDollars: decimal("19.995")) == 2_000)
    #expect(try Money.cents(fromDollars: decimal("-19.995")) == -2_000)
  }

  @Test(
    "Cents survive a round trip through Decimal",
    arguments: [-99, 0, 1, 99, 1_234, 123_456_789_012]
  )
  func roundTrip(cents: Int) {
    #expect(Money.cents(fromDollars: Money.dollars(fromCents: cents)) == cents)
  }

  @Test("Cents arithmetic is exact where binary floating point is not")
  func arithmeticIsExact() throws {
    // 0.1 + 0.2 != 0.3 in Double; integer cents and Decimal stay exact.
    let tenCents = try decimal("0.1")
    let twentyCents = try decimal("0.2")
    #expect(Money.cents(fromDollars: tenCents + twentyCents) == 30)
    #expect(Money.cents(fromDollars: tenCents) + Money.cents(fromDollars: twentyCents) == 30)

    let total = Array(repeating: 10, count: 1_000).reduce(0, +)
    #expect(total == 10_000)
    #expect(Money.format(cents: total, locale: Money.fixedLocale) == "$100.00")
  }

  private func decimal(_ string: String) throws -> Decimal {
    try #require(Decimal(string: string))
  }
}
