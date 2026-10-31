import Foundation
import SwiftData
import Testing

@testable import Runway

struct ExpenseDraftTests {
  let calendar = Calendar.gregorian("America/Chicago")

  @Test("Amounts are required, positive, bounded, and parsed without rounding")
  func amounts() {
    var draft = ExpenseDraft()
    draft.locale = Money.fixedLocale
    for text in ["", " ", "0", "0.00", "-1", "1.234", "no", "10000000.01"] {
      draft.amountText = text
      #expect(draft.amountCents == nil)
      #expect(draft.validationMessage != nil)
    }
    for text in ["$", " $ "] {
      draft.amountText = text
      #expect(draft.amountCents == nil)
      #expect(draft.validationMessage == "Enter an amount.")
    }
    for (text, cents) in [("$1,234.50", 123_450), (".01", 1), ("12", 1_200), ("$.50", 50)] {
      draft.amountText = text
      #expect(draft.amountCents == cents)
      #expect(draft.validationMessage == nil)
      draft.isRefund = true
      #expect(draft.amountCents == -cents)
      draft.isRefund = false
    }
    draft.locale = Locale(identifier: "de_DE")
    draft.amountText = "12,50"
    #expect(draft.amountCents == 1_250)
  }

  @Test("Dates default to now and clamp to the current period through now")
  func dates() {
    let start = calendar.date(2026, 6, 1)
    let now = calendar.date(2026, 6, 4, 12)
    var draft = ExpenseDraft(now: now)
    #expect(draft.date == now)
    #expect(ExpenseDraft.allowedDates(periodStart: start, now: now) == start...now)
    draft.date = start.addingTimeInterval(-1)
    #expect(draft.clampedDate(periodStart: start, now: now) == start)
    draft.date = now.addingTimeInterval(1)
    #expect(draft.clampedDate(periodStart: start, now: now) == now)
    draft.date = calendar.date(2026, 6, 2)
    #expect(draft.clampedDate(periodStart: start, now: now) == draft.date)
    #expect(ExpenseDraft.allowedDates(periodStart: now, now: start) == start...start)
  }

  @Test("Draft saves through the service and undo restores the allowance")
  func saveAndUndo() throws {
    let container = try RunwayModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    let now = calendar.date(2026, 6, 1, 12)
    let budget = Budget(
      periodLength: .weekly,
      periodStart: calendar.startOfDay(for: now),
      spendablePerPeriodCents: 70_000
    )
    context.insert(budget)
    let service = CategoryService(context: context)
    var draft = ExpenseDraft(now: now)
    draft.locale = Money.fixedLocale
    #expect(try draft.createExpense(using: service, periodStart: now, now: now) == nil)
    #expect(try context.fetchCount(FetchDescriptor<Expense>()) == 0)
    draft.amountText = "12.50"
    draft.note = " Lunch "
    let expense = try #require(
      try draft.createExpense(
        using: service,
        periodStart: budget.periodStart,
        now: now
      )
    )
    try context.save()
    #expect(expense.category?.isSystem == true)
    #expect(expense.note == "Lunch")
    #expect(expense.createdAt == now)
    let engine = AllowanceEngine(calendar: calendar)
    let saved = try context.fetch(FetchDescriptor<Expense>())
    let beforeUndo = engine.currentAllowance(
      budget: BudgetSnapshot(budget),
      expenses: saved.map { ExpenseSnapshot($0) },
      now: now
    )
    #expect(beforeUndo.remainingTodayCents == 8_750)
    let undo = ExpenseUndo(expense: expense, now: now)
    #expect(try undo.undo(in: context, now: now.addingTimeInterval(4)))
    let remaining = try context.fetch(FetchDescriptor<Expense>())
    #expect(remaining.isEmpty)
    let afterUndo = engine.currentAllowance(
      budget: BudgetSnapshot(budget),
      expenses: remaining.map { ExpenseSnapshot($0) },
      now: now
    )
    #expect(afterUndo.remainingTodayCents == 10_000)
  }

  @Test("Refunds save negative cents and expired undo leaves the expense intact")
  func refundAndExpiry() throws {
    let container = try RunwayModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    let now = calendar.date(2026, 6, 4, 12)
    let start = calendar.date(2026, 6, 1)
    let service = CategoryService(context: context)
    let category = try service.seed()
    var draft = ExpenseDraft(now: start.addingTimeInterval(-1))
    draft.amountText = "5"
    draft.isRefund = true
    let expense = try #require(
      try draft.createExpense(using: service, category: category, periodStart: start, now: now)
    )
    try context.save()
    #expect(expense.amountCents == -500)
    #expect(expense.date == start)
    #expect(expense.category === category)
    let undo = ExpenseUndo(expense: expense, now: now)
    #expect(try !undo.undo(in: context, now: now.addingTimeInterval(5)))
    #expect(try context.fetchCount(FetchDescriptor<Expense>()) == 1)
  }

  @Test("Backdating across midnight stays inside the period and future dates clamp to now")
  func midnightClamp() {
    let now = calendar.date(2026, 6, 4, 0, 0, 30)
    let start = calendar.date(2026, 6, 1)
    var draft = ExpenseDraft(now: now)
    draft.date = calendar.date(2026, 6, 3, 23, 59)
    #expect(draft.clampedDate(periodStart: start, now: now) == draft.date)
    draft.date = now.addingTimeInterval(1)
    #expect(draft.clampedDate(periodStart: start, now: now) == now)
    #expect(draft.clampedDate(periodStart: calendar.startOfDay(for: now), now: now) == now)
    draft.date = calendar.date(2026, 6, 3, 23, 59)
    let boundary = calendar.startOfDay(for: now)
    #expect(draft.clampedDate(periodStart: boundary, now: now) == boundary)
  }

  @Test("Two quick saves persist both expenses and the latest undo deletes only the second")
  func consecutiveSaves() throws {
    let container = try RunwayModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    let service = CategoryService(context: context)
    let now = calendar.date(2026, 6, 4, 12)
    let start = calendar.date(2026, 6, 1)
    var draft = ExpenseDraft(now: now)
    draft.locale = Money.fixedLocale
    draft.amountText = "12.50"
    let first = try #require(
      try draft.createExpense(using: service, periodStart: start, now: now)
    )
    try context.save()
    var undo = ExpenseUndo(expense: first, now: now)
    draft.amountText = "5"
    let second = try #require(
      try draft.createExpense(using: service, periodStart: start, now: now.addingTimeInterval(1))
    )
    try context.save()
    undo = ExpenseUndo(expense: second, now: now.addingTimeInterval(1))
    let loaded = ModelContext(container)
    let saved = try loaded.fetch(FetchDescriptor<Expense>())
    #expect(saved.map(\.amountCents).sorted() == [500, 1_250])
    #expect(try undo.undo(in: context, now: now.addingTimeInterval(2)))
    let afterUndo = ModelContext(container)
    let remaining = try afterUndo.fetch(FetchDescriptor<Expense>())
    #expect(remaining.map(\.persistentModelID) == [first.persistentModelID])
    #expect(remaining.map(\.amountCents) == [1_250])
  }

}
