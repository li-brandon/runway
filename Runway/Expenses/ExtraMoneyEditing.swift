import Foundation

/// The form state for editing saved extra money. Amounts follow `AddMoneyView`: above zero only.
/// Money that came in negative from a backup stays negative, since the form has no sign to show.
struct ExtraMoneyDraft {
  var amountText: String
  var note: String
  var date: Date
  var locale: Locale = .autoupdatingCurrent

  private let originalDate: Date
  private let isNegative: Bool

  init(extra: ExtraMoney) {
    amountText = BudgetDraft.text(fromCents: abs(extra.amountCents))
    note = extra.note
    date = extra.date
    originalDate = extra.date
    isNegative = extra.amountCents < 0
  }

  var parsed: BudgetDraft.ParsedAmount {
    BudgetDraft.parseAmount(amountText, locale: locale)
  }

  /// The amount to save, if it's valid and above zero.
  var amountCents: Int? {
    guard case .cents(let cents) = parsed, cents > 0 else { return nil }
    return isNegative ? -cents : cents
  }

  /// The date to save: exactly the original unless the user chose another, which is limited to
  /// `period` through now and stored as local midnight, like every day-only date.
  func savedDate(in period: BudgetPeriod, now: Date, calendar: Calendar) -> Date {
    guard date != originalDate else { return originalDate }
    let range = ExpenseDraft.allowedDates(in: period, now: now)
    return calendar.startOfDay(for: min(max(date, range.lowerBound), range.upperBound))
  }

  /// Applies the draft to `extra`. Returns `false` and changes nothing when the amount is invalid.
  @discardableResult
  func update(
    _ extra: ExtraMoney,
    period: BudgetPeriod,
    now: Date,
    calendar: Calendar
  ) -> Bool {
    guard let amountCents else { return false }
    extra.amountCents = amountCents
    extra.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
    extra.date = savedDate(in: period, now: now, calendar: calendar)
    return true
  }
}
