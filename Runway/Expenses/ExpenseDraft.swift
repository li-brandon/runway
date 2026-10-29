import Foundation
import SwiftData

/// Editable quick-log values. Amounts use the same decimal parser as budget setup.
struct ExpenseDraft {
  var amountText = ""
  var note = ""
  var isRefund = false
  var date: Date
  var locale: Locale = .autoupdatingCurrent

  init(now: Date = .now) {
    date = now
  }

  var validationMessage: String? {
    switch BudgetDraft.parseAmount(amountText, locale: locale) {
    case .empty: "Enter an amount."
    case .cents(let cents): cents == 0 ? "Enter an amount greater than zero." : nil
    case .failure(let issue): issue.message
    }
  }

  var amountCents: Int? {
    guard validationMessage == nil,
      case .cents(let cents) = BudgetDraft.parseAmount(amountText, locale: locale)
    else { return nil }
    return isRefund ? -cents : cents
  }

  static func allowedDates(periodStart: Date, now: Date) -> ClosedRange<Date> {
    min(periodStart, now)...now
  }

  func clampedDate(periodStart: Date, now: Date) -> Date {
    let range = Self.allowedDates(periodStart: periodStart, now: now)
    return min(max(date, range.lowerBound), range.upperBound)
  }

  func createExpense(
    using service: CategoryService,
    category: Category? = nil,
    periodStart: Date,
    now: Date
  ) throws -> Expense? {
    guard let amountCents else { return nil }
    return try service.createExpense(
      amountCents: amountCents,
      note: note.trimmingCharacters(in: .whitespacesAndNewlines),
      date: clampedDate(periodStart: periodStart, now: now),
      category: category,
      now: now
    )
  }
}

/// A single undo opportunity. A new save replaces the previous opportunity.
struct ExpenseUndo {
  let expense: Expense
  let expiresAt: Date

  init(expense: Expense, now: Date) {
    self.expense = expense
    expiresAt = now.addingTimeInterval(5)
  }

  @discardableResult
  func undo(in context: ModelContext, now: Date) throws -> Bool {
    guard now < expiresAt else { return false }
    context.delete(expense)
    try context.save()
    return true
  }
}
