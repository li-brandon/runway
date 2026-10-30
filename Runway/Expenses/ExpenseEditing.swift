import Foundation
import SwiftData

/// Editing a saved expense reuses the quick-log draft: the same parsing, validation, and refund
/// sign, with the date limited to the expense's own period and never after now.
extension ExpenseDraft {
  /// Prefills the draft from `expense`. Refunds show their positive amount with Refund on.
  init(expense: Expense) {
    self.init(now: expense.date)
    amountText = BudgetDraft.text(fromCents: abs(expense.amountCents))
    note = expense.note
    isRefund = expense.amountCents < 0
  }

  /// From the period's first moment through the earlier of now and the period's last second.
  /// A period that starts after now allows now only, like `allowedDates(periodStart:now:)`.
  static func allowedDates(in period: BudgetPeriod, now: Date) -> ClosedRange<Date> {
    let upper = min(period.end.addingTimeInterval(-1), now)
    return min(period.start, upper)...upper
  }

  func clampedDate(in period: BudgetPeriod, now: Date) -> Date {
    let range = Self.allowedDates(in: period, now: now)
    return min(max(date, range.lowerBound), range.upperBound)
  }

  /// Applies the draft to `expense` through `CategoryService`. Returns `false` and changes nothing
  /// when the amount is invalid. A `nil` category keeps the expense's current one.
  @discardableResult
  func update(
    _ expense: Expense,
    using service: CategoryService,
    category: Category? = nil,
    period: BudgetPeriod,
    now: Date
  ) throws -> Bool {
    guard let amountCents else { return false }
    try service.updateExpense(
      expense,
      amountCents: amountCents,
      note: note.trimmingCharacters(in: .whitespacesAndNewlines),
      date: clampedDate(in: period, now: now),
      category: category
    )
    return true
  }
}

/// A deleted expense that can be restored for five seconds, like `ExpenseUndo`. Restoring creates
/// it again through `CategoryService.createExpense` with the same amount, note, spending date,
/// logging time, and category (Other if that category was deleted meanwhile).
struct ExpenseDeletion {
  let amountCents: Int
  let note: String
  let date: Date
  let createdAt: Date
  let categoryID: PersistentIdentifier?
  let expiresAt: Date

  /// Deletes and saves `expense`. On a save failure the caller rolls back.
  static func delete(
    _ expense: Expense,
    in context: ModelContext,
    now: Date
  ) throws -> ExpenseDeletion {
    let deletion = ExpenseDeletion(
      amountCents: expense.amountCents,
      note: expense.note,
      date: expense.date,
      createdAt: expense.createdAt,
      categoryID: expense.category?.persistentModelID,
      expiresAt: now.addingTimeInterval(5)
    )
    context.delete(expense)
    try context.save()
    return deletion
  }

  /// Recreates and saves the expense, or returns `nil` once the undo has expired.
  @discardableResult
  func undo(in context: ModelContext, now: Date) throws -> Expense? {
    guard now < expiresAt else { return nil }
    let service = CategoryService(context: context)
    // Look the category up again: it may have been deleted since.
    let category = try service.categories().first { $0.persistentModelID == categoryID }
    let expense = try service.createExpense(
      amountCents: amountCents,
      note: note,
      date: date,
      category: category,
      now: createdAt
    )
    try context.save()
    return expense
  }
}

/// History's single undo. Only the most recent delete can be undone: a new delete replaces the
/// pending one, which stays deleted (it was saved when deleted) and loses its undo.
struct ExpenseUndoSlot {
  private(set) var pending: ExpenseDeletion?

  /// Deletes and saves `expense`, making it the only one Undo restores. On a save failure the
  /// pending deletion is kept and the caller rolls back.
  mutating func delete(_ expense: Expense, in context: ModelContext, now: Date) throws {
    pending = try ExpenseDeletion.delete(expense, in: context, now: now)
  }

  /// Restores the latest deletion and empties the slot. Returns `nil`, and empties the slot, when
  /// there is nothing to undo or it has expired. On a save failure the slot is kept.
  @discardableResult
  mutating func undo(in context: ModelContext, now: Date) throws -> Expense? {
    guard let deletion = pending else { return nil }
    let restored = try deletion.undo(in: context, now: now)
    pending = nil
    return restored
  }

  /// Empties the slot if its deletion still expires at `deadline`, so a later delete keeps its
  /// own five seconds.
  mutating func expire(at deadline: Date) {
    if pending?.expiresAt == deadline { pending = nil }
  }
}
