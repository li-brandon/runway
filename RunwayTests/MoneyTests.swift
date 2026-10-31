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

  @Test(
    "Abbreviates large amounts, moving up a unit rather than showing 1000",
    arguments: zip(
      [
        100_000, 95_000_000, 99_994_999, 99_995_000, 1_230_000_000, 120_000_000_000,
        125_000_000_000, 99_995_000_000,
      ],
      ["$1K", "$950K", "$999.9K", "$1M", "$12.3M", "$1.2B", "$1.3B", "$1B"]
    )
  )
  func abbreviates(cents: Int, expected: String) {
    #expect(Money.abbreviated(cents: cents, locale: Money.fixedLocale) == expected)
    #expect(Money.abbreviated(cents: -cents, locale: Money.fixedLocale) == "-\(expected)")
  }

  @Test("Abbreviates the import maximum without an ellipsis")
  func abbreviatesImportMaximum() {
    let maximum = DataImport.maximumMagnitudeCents
    #expect(Money.abbreviated(cents: maximum, locale: Money.fixedLocale) == "$100B")
    #expect(Money.abbreviated(cents: -maximum, locale: Money.fixedLocale) == "-$100B")
  }

  @Test("Amounts under $1,000 stay exact", arguments: [0, 1_234, 99_999, -99_999])
  func shortAmountsStayExact(cents: Int) {
    let abbreviated = Money.abbreviated(cents: cents, locale: Money.fixedLocale)
    #expect(abbreviated == Money.format(cents: cents, locale: Money.fixedLocale))
  }

  @Test("Abbreviating handles every Int without an ellipsis", arguments: [Int.max, Int.min])
  func abbreviatesExtremes(cents: Int) {
    #expect(!Money.abbreviated(cents: cents, locale: Money.fixedLocale).contains("…"))
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
