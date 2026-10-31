import Foundation
import SwiftData

/// The form state for editing saved extra money. The amount is a magnitude above zero, and
/// `isNegative` is its sign, so money that came in negative from a backup can stay or be flipped.
struct ExtraMoneyDraft {
  var amountText: String
  var note: String
  var date: Date
  var isNegative: Bool
  var locale: Locale = .autoupdatingCurrent

  private let originalDate: Date

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

/// Deleted extra money that can be restored for five seconds, like `ExpenseDeletion`. Restoring
/// creates it again with the same amount, sign, note, and exact date.
struct ExtraMoneyDeletion {
  let amountCents: Int
  let note: String
  let date: Date
  let budget: Budget
  let expiresAt: Date

  /// Deletes and saves `extra`. On a save failure the caller rolls back.
  static func delete(
    _ extra: ExtraMoney,
    from budget: Budget,
    in context: ModelContext,
    now: Date
  ) throws -> ExtraMoneyDeletion {
    let deletion = ExtraMoneyDeletion(
      amountCents: extra.amountCents,
      note: extra.note,
      date: extra.date,
      budget: budget,
      expiresAt: now.addingTimeInterval(5)
    )
    budget.removeExtraMoney(extra)
    try context.save()
    return deletion
  }

  /// Recreates and saves the money, or returns `nil` once the undo has expired. Not through
  /// `Budget.addExtraMoney`, which would move an imported date to local midnight.
  @discardableResult
  func undo(in context: ModelContext, now: Date) throws -> ExtraMoney? {
    guard now < expiresAt else { return nil }
    let extra = ExtraMoney(amountCents: amountCents, note: note, date: date)
    context.insert(extra)
    budget.extraMoney.append(extra)
    try context.save()
    return extra
  }
}
