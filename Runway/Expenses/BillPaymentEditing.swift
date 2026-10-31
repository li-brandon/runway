import Foundation
import SwiftData

extension BillPayment {
  /// What the period gets back from the bill while this mark stands.
  var creditCents: Int {
    isCleared ? 0 : plannedCents - paidCents
  }
}

/// The form state for editing a bill mark dated before the budget. Paid needs an amount, which can
/// be zero as on This Period; skipped and unpaid have none.
struct BillPaymentDraft {
  enum Status: Hashable {
    case paid
    case skipped
    case unpaid
  }

  var status: Status
  var amountText: String
  var date: Date
  var locale: Locale = .autoupdatingCurrent

  private let originalDate: Date

  /// A mark that wasn't paid prefills the planned amount, in case it's switched to Paid.
  init(mark: BillPayment) {
    if mark.isCleared {
      status = .unpaid
    } else if mark.isSkipped {
      status = .skipped
    } else {
      status = .paid
    }
    let amount = status == .paid ? mark.paidCents : mark.plannedCents
    amountText = BudgetDraft.text(fromCents: abs(amount))
    date = mark.date
    originalDate = mark.date
  }

  var parsed: BudgetDraft.ParsedAmount {
    BudgetDraft.parseAmount(amountText, locale: locale)
  }

  /// The paid amount to save, if it's valid.
  var paidCents: Int? {
    guard status == .paid else { return 0 }
    guard case .cents(let cents) = parsed, cents >= 0 else { return nil }
    return cents
  }

  /// The date to save: exactly the original unless the user chose another, which is limited to
  /// `period` through now and stored as local midnight, like every day-only date.
  func savedDate(in period: BudgetPeriod, now: Date, calendar: Calendar) -> Date {
    guard date != originalDate else { return originalDate }
    let range = ExpenseDraft.allowedDates(in: period, now: now)
    return calendar.startOfDay(for: min(max(date, range.lowerBound), range.upperBound))
  }

  /// Applies the draft to `mark`, moving its adjustment by the change in what it gives back.
  /// Returns `false` and changes nothing when the amount is invalid.
  @discardableResult
  func update(
    _ mark: BillPayment,
    period: BudgetPeriod,
    now: Date,
    calendar: Calendar
  ) -> Bool {
    guard let paid = paidCents else { return false }
    let previousCredit = mark.creditCents
    mark.isSkipped = status == .skipped
    mark.isCleared = status == .unpaid
    mark.paidCents = paid
    mark.adjustmentCents += mark.creditCents - previousCredit
    mark.date = savedDate(in: period, now: now, calendar: calendar)
    return true
  }
}

/// A deleted bill mark that can be restored for five seconds, like `ExpenseDeletion`. Restoring
/// creates it again with the same fields and exact date, and with its bill unless that was deleted
/// meanwhile.
struct BillPaymentDeletion {
  let isSkipped: Bool
  let isCleared: Bool
  let plannedCents: Int
  let paidCents: Int
  let adjustmentCents: Int
  let sequence: Int
  let date: Date
  let billID: PersistentIdentifier?
  let budget: Budget
  let expiresAt: Date

  /// Deletes and saves `mark`. On a save failure the caller rolls back.
  static func delete(
    _ mark: BillPayment,
    from budget: Budget,
    in context: ModelContext,
    now: Date
  ) throws -> BillPaymentDeletion {
    let deletion = BillPaymentDeletion(
      isSkipped: mark.isSkipped,
      isCleared: mark.isCleared,
      plannedCents: mark.plannedCents,
      paidCents: mark.paidCents,
      adjustmentCents: mark.adjustmentCents,
      sequence: mark.sequence,
      date: mark.date,
      billID: mark.bill?.persistentModelID,
      budget: budget,
      expiresAt: now.addingTimeInterval(5)
    )
    budget.removeBillPayment(mark)
    try context.save()
    return deletion
  }

  /// Recreates and saves the mark, or returns `nil` once the undo has expired.
  @discardableResult
  func undo(in context: ModelContext, now: Date) throws -> BillPayment? {
    guard now < expiresAt else { return nil }
    let mark = BillPayment(
      isSkipped: isSkipped,
      isCleared: isCleared,
      plannedCents: plannedCents,
      paidCents: paidCents,
      adjustmentCents: adjustmentCents,
      sequence: sequence,
      date: date
    )
    context.insert(mark)
    budget.billPayments.append(mark)
    // Look the bill up again: it may have been deleted since.
    mark.bill = budget.fixedBills.first { $0.persistentModelID == billID }
    try context.save()
    return mark
  }
}
