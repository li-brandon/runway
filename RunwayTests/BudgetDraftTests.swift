import Foundation
import Testing

@testable import Runway

/// Parsing, validation, and the live available amount. Uses `en_US` unless a test says otherwise.
struct BudgetDraftTests {
  let locale = Money.fixedLocale
  let calendar = Calendar.gregorian("America/Chicago")

  func makeDraft() -> BudgetDraft {
    BudgetDraft(periodStart: calendar.date(2026, 6, 5), locale: locale)
  }

  func bill(_ name: String, _ amountText: String, dueDay: Int? = nil) -> BudgetDraft.Bill {
    BudgetDraft.Bill(name: name, amountText: amountText, dueDay: dueDay)
  }

  // MARK: - Defaults

  @Test("A new draft defaults to biweekly with carryover on and nothing entered")
  func defaults() {
    let draft = makeDraft()
    #expect(draft.periodLength == .biweekly)
    #expect(draft.carryoverEnabled)
    #expect(draft.periodStart == calendar.date(2026, 6, 5))
    #expect(draft.spendableText.isEmpty)
    #expect(draft.incomeText.isEmpty)
    #expect(draft.savingsText.isEmpty)
    #expect(draft.bills.isEmpty)
    #expect(draft.availableCents == nil)
    #expect(!draft.showsLowAvailableWarning)
    // Spendable is the one required field.
    #expect(draft.issues == [.spendable: .required])
    #expect(!draft.canSave)
  }

  // MARK: - Parsing

  @Test(
    "Parses dollar text into cents",
    arguments: zip(
      [
        "12.34", "$1,234.5", "$2,400.50", "2400.50", " 7 ", ".5", "5.", "0", "0.07",
        "10000000", "$ 2,400.00", "2400.5", "$2,400",
      ],
      [
        1_234, 123_450, 240_050, 240_050, 700, 50, 500, 0, 7, 1_000_000_000, 240_000,
        240_050, 240_000,
      ]
    )
  )
  func parsesCents(text: String, cents: Int) {
    #expect(BudgetDraft.parseAmount(text, locale: locale) == .cents(cents))
  }

  @Test("Blank text is empty, not zero", arguments: ["", "   ", "$"])
  func parsesEmpty(text: String) {
    #expect(BudgetDraft.parseAmount(text, locale: locale) == .empty)
  }

  @Test(
    "Rejects text that isn't a dollar amount",
    arguments: ["abc", "12a", "1.2.3", "12.345", "-", ".", "1e3", "١٢"]
  )
  func rejectsInvalid(text: String) {
    #expect(BudgetDraft.parseAmount(text, locale: locale) == .failure(.invalid))
  }

  @Test("Rejects negative amounts", arguments: ["-5", "-$5", "$-0.01", "- 12.34"])
  func rejectsNegative(text: String) {
    #expect(BudgetDraft.parseAmount(text, locale: locale) == .failure(.negative))
  }

  @Test("Rejects amounts over the maximum", arguments: ["10000000.01", "999999999999999999999"])
  func rejectsTooLarge(text: String) {
    #expect(BudgetDraft.parseAmount(text, locale: locale) == .failure(.tooLarge))
  }

  @Test("Uses the locale's decimal and grouping separators")
  func parsesWithLocale() {
    let german = Locale(identifier: "de_DE")
    #expect(BudgetDraft.parseAmount("1.234,56", locale: german) == .cents(123_456))
    #expect(BudgetDraft.parseAmount("12,5", locale: german) == .cents(1_250))
    #expect(BudgetDraft.text(fromCents: 4_550, locale: german) == "$45.50")
  }

  @Test(
    "Formats cents as editable USD",
    arguments: zip(
      [0, 7, 4_550, 240_000, 123_401],
      ["$0", "$0.07", "$45.50", "$2,400", "$1,234.01"]
    )
  )
  func formatsText(cents: Int, text: String) {
    #expect(BudgetDraft.text(fromCents: cents, locale: locale) == text)
    #expect(BudgetDraft.parseAmount(text, locale: locale) == .cents(cents))
  }

  @Test("Arabic locale formats ASCII USD and round-trips", arguments: [0, 7, 240_050, 240_000])
  func formatsLatinDigits(cents: Int) {
    let arabic = Locale(identifier: "ar_SA")
    let text = BudgetDraft.text(fromCents: cents, locale: arabic)
    #expect(text.allSatisfy { "$,.0123456789".contains($0) })
    #expect(BudgetDraft.parseAmount(text, locale: arabic) == .cents(cents))
  }

  @Test(
    "Formats valid amounts as currency for display",
    arguments: zip(
      ["2400", "45.5", "$1,234.56", "0"],
      ["$2,400", "$45.50", "$1,234.56", "$0"]
    )
  )
  func formatsDisplayText(text: String, displayText: String) {
    #expect(BudgetDraft.displayText(for: text, locale: locale) == displayText)
  }

  @Test(
    "Display text parses back to the same cents",
    arguments: ["en_US", "de_DE", "fr_FR", "en_CA", "ja_JP", "de_CH", "ar_SA"]
  )
  func displayTextRoundTrips(identifier: String) {
    let locale = Locale(identifier: identifier)
    for cents in [0, 7, 4_550, 240_000, 123_456_789] {
      let text = BudgetDraft.text(fromCents: cents, locale: locale)
      let displayText = BudgetDraft.displayText(for: text, locale: locale)
      #expect(BudgetDraft.parseAmount(displayText, locale: locale) == .cents(cents))
      // Formatting again doesn't change it.
      #expect(BudgetDraft.displayText(for: displayText, locale: locale) == displayText)
    }
  }

  @Test("Leaves empty or invalid text alone", arguments: ["", "  ", "abc", "-5", "12.345"])
  func displayTextKeepsInvalid(text: String) {
    #expect(BudgetDraft.displayText(for: text, locale: locale) == text)
  }

  // MARK: - Available and validation

  @Test("Available is spendable minus bills minus savings")
  func available() {
    var draft = makeDraft()
    draft.spendableText = "2,000"
    draft.bills = [bill("Rent", "900", dueDay: 1), bill("Phone", "45.50")]
    draft.savingsText = "200"
    // 2,000 - 945.50 - 200 = 854.50.
    #expect(draft.availableCents == 85_450)
    #expect(!draft.showsLowAvailableWarning)
    #expect(draft.issues.isEmpty)
    #expect(draft.canSave)
  }

  @Test("While editing, an empty bill amount or savings counts as zero but a bill still needs one")
  func emptyOptionalAmounts() {
    var draft = makeDraft()
    draft.spendableText = "500"
    draft.addBill()
    let id = draft.bills[0].id
    #expect(draft.availableCents == 50_000)
    #expect(draft.issues == [.billName(id): .required, .billAmount(id): .required])
    #expect(!draft.canSave)

    draft.bills[0].name = "  "
    draft.bills[0].amountText = "50"
    #expect(draft.issues == [.billName(id): .required])
    draft.bills[0].name = "Gym"
    #expect(draft.canSave)
  }

  @Test("Any invalid amount hides available and blocks saving")
  func invalidAmounts() {
    var draft = makeDraft()
    draft.spendableText = "500"
    draft.savingsText = "-20"
    #expect(draft.availableCents == nil)
    #expect(draft.issues == [.savings: .negative])
    #expect(!draft.canSave)

    draft.savingsText = ""
    draft.incomeText = "lots"
    // Income doesn't affect available, but it still has to be valid to save.
    #expect(draft.availableCents == 50_000)
    #expect(draft.issues == [.income: .invalid])

    draft.incomeText = ""
    draft.spendableText = "-500"
    #expect(draft.availableCents == nil)
    #expect(draft.issues == [.spendable: .negative])
  }

  @Test("Zero or negative available warns but can still be saved", arguments: ["1000", "1200"])
  func lowAvailableWarns(rentText: String) {
    var draft = makeDraft()
    draft.spendableText = "1000"
    draft.bills = [bill("Rent", rentText)]
    #expect((draft.availableCents ?? 1) <= 0)
    #expect(draft.showsLowAvailableWarning)
    #expect(draft.canSave)
  }

  // MARK: - Income

  @Test("Use income copies the entered income into spendable")
  func useIncome() {
    var draft = makeDraft()
    #expect(!draft.canUseIncome)

    draft.incomeText = "$2,400.5"
    #expect(draft.incomeCents == 240_050)
    #expect(draft.canUseIncome)
    draft.useIncomeForSpendable()
    #expect(draft.spendableText == "$2,400.50")
    #expect(draft.availableCents == 240_050)
    // Already equal, so the button has nothing to do.
    #expect(!draft.canUseIncome)

    draft.incomeText = "0"
    #expect(!draft.canUseIncome)
    draft.incomeText = "abc"
    #expect(draft.incomeCents == nil)
    #expect(!draft.canUseIncome)
  }
}
