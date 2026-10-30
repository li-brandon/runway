import Foundation
import SwiftData
import Testing

@testable import Runway

/// Editing and deleting saved expenses from History, recomputed through the engines.
@MainActor
struct HistoryEditingTests {
  let calendar = Calendar.gregorian("America/Chicago")
  let container: ModelContainer
  let context: ModelContext
  let budget: Budget

  init() throws {
    container = try RunwayModelContainer.make(inMemory: true)
    context = ModelContext(container)
    try CategoryService(context: context).seed()
    // Weekly, $700 available, starting Monday June 1, 2026.
    budget = Budget(
      periodLength: .weekly,
      periodStart: Calendar.gregorian("America/Chicago").date(2026, 6, 1),
      spendablePerPeriodCents: 70_000
    )
    context.insert(budget)
    try context.save()
  }

  var service: CategoryService { CategoryService(context: context) }

  func category(_ name: String) throws -> RunwaySchemaV1.Category {
    try #require(try service.categories().first { $0.name == name })
  }

  func savedExpenses() throws -> [Expense] {
    try context.fetch(FetchDescriptor<Expense>(sortBy: [SortDescriptor(\.date)]))
  }

  func history(now: Date) throws -> [HistoryPeriod<PersistentIdentifier?>] {
    HistoryEngine(calendar: calendar).periods(
      budget: BudgetSnapshot(budget),
      expenses: try savedExpenses().map { HistoryExpense<PersistentIdentifier?>($0) },
      now: now
    )
  }

  func today(now: Date) throws -> AllowanceResult {
    AllowanceEngine(calendar: calendar).currentAllowance(
      budget: BudgetSnapshot(budget),
      expenses: try savedExpenses().map { ExpenseSnapshot($0) },
      now: now
    )
  }

  func period(containing date: Date) -> BudgetPeriod {
    AllowanceEngine(calendar: calendar).period(containing: date, of: BudgetSnapshot(budget))
  }

  @Test("The edit draft prefills amounts with Latin digits and refunds as positive with Refund")
  func prefill() throws {
    let logged = calendar.date(2026, 6, 2, 9)
    let refund = try service.createExpense(
      amountCents: -2_500,
      note: "Returned shirt",
      date: logged,
      now: logged
    )
    let lunch = try service.createExpense(amountCents: 1_250, date: logged, now: logged)
    let refundDraft = ExpenseDraft(expense: refund)
    #expect(refundDraft.amountText == "$25")
    #expect(refundDraft.isRefund)
    #expect(refundDraft.note == "Returned shirt")
    #expect(refundDraft.date == logged)
    #expect(refundDraft.amountCents == -2_500)
    let lunchDraft = ExpenseDraft(expense: lunch)
    #expect(lunchDraft.amountText == "$12.50")
    #expect(!lunchDraft.isRefund)
    #expect(lunchDraft.amountCents == 1_250)
  }

  @Test("Editing amount, note, date, and category recomputes earlier days, later days, and Today")
  func editRecomputes() throws {
    let now = calendar.date(2026, 6, 4, 12)
    let dinner = calendar.date(2026, 6, 3, 19)
    let expense = try service.createExpense(
      amountCents: 7_000,
      note: "Dinner",
      date: dinner,
      category: try category("Food"),
      now: dinner
    )
    try context.save()
    let before = try history(now: now)[0]
    #expect(before.days.map(\.allowanceCents) == [15_750, 14_000, 11_666, 10_000])
    #expect(try today(now: now).allowanceTodayCents == 15_750)

    var draft = ExpenseDraft(expense: expense)
    draft.locale = Money.fixedLocale
    draft.amountText = "30"
    draft.note = " Market "
    draft.date = calendar.date(2026, 6, 1, 19)
    let groceries = try category("Groceries")
    let updated = try draft.update(
      expense,
      using: service,
      category: groceries,
      period: period(containing: now),
      now: now
    )
    #expect(updated)
    try context.save()

    let saved = try #require(try savedExpenses().first)
    #expect(saved.amountCents == 3_000)
    #expect(saved.note == "Market")
    #expect(saved.date == calendar.date(2026, 6, 1, 19))
    #expect(saved.category === groceries)
    #expect(saved.createdAt == dinner)

    let after = try history(now: now)[0]
    #expect(after.days.map(\.allowanceCents) == [16_750, 13_400, 11_166, 10_000])
    #expect(after.days.map(\.spentCents) == [0, 0, 0, 3_000])
    #expect(after.categories.map(\.categoryID) == [groceries.persistentModelID])
    #expect(after.categories.map(\.spentCents) == [3_000])
    #expect(try today(now: now).allowanceTodayCents == 16_750)
  }

  @Test("Editing a past period's expense changes its carry-out and the next period's numbers")
  func editPastPeriod() throws {
    let now = calendar.date(2026, 6, 10, 12)
    let date = calendar.date(2026, 6, 3, 12)
    let expense = try service.createExpense(amountCents: 60_000, date: date, now: date)
    try context.save()
    #expect(try history(now: now).map(\.carryInCents) == [10_000, 0])
    #expect(try today(now: now).allowanceTodayCents == 80_000 / 5)

    var draft = ExpenseDraft(expense: expense)
    draft.isRefund = true
    // A date after its period clamps to the period's last second rather than moving periods.
    draft.date = now
    let pastPeriod = period(containing: date)
    #expect(try draft.update(expense, using: service, period: pastPeriod, now: now))
    try context.save()

    #expect(expense.amountCents == -60_000)
    #expect(expense.date == calendar.date(2026, 6, 8).addingTimeInterval(-1))
    #expect(expense.category?.isSystem == true)
    let periods = try history(now: now)
    #expect(periods.map(\.carryInCents) == [130_000, 0])
    #expect(periods[1].carryOutCents == 130_000)
    #expect(try today(now: now).allowanceTodayCents == 200_000 / 5)
  }

  @Test("Edit dates stay within the expense's period and never pass now")
  func editDateRange() {
    let period = BudgetPeriod(
      index: 0,
      start: calendar.date(2026, 6, 1),
      end: calendar.date(2026, 6, 8)
    )
    let lastSecond = calendar.date(2026, 6, 7, 23, 59, 59)
    let later = calendar.date(2026, 6, 20, 12)
    #expect(ExpenseDraft.allowedDates(in: period, now: later) == period.start...lastSecond)
    let midPeriod = calendar.date(2026, 6, 4, 12)
    #expect(ExpenseDraft.allowedDates(in: period, now: midPeriod) == period.start...midPeriod)
    let before = calendar.date(2026, 5, 30, 12)
    #expect(ExpenseDraft.allowedDates(in: period, now: before) == before...before)

    var draft = ExpenseDraft(now: calendar.date(2026, 5, 31, 23))
    #expect(draft.clampedDate(in: period, now: midPeriod) == period.start)
    draft.date = calendar.date(2026, 6, 5, 9)
    #expect(draft.clampedDate(in: period, now: midPeriod) == midPeriod)
    draft.date = calendar.date(2026, 6, 3, 9)
    #expect(draft.clampedDate(in: period, now: midPeriod) == draft.date)
  }

  @Test("An invalid edit changes nothing")
  func invalidEdit() throws {
    let date = calendar.date(2026, 6, 2, 9)
    let expense = try service.createExpense(amountCents: 1_000, note: "Coffee", date: date)
    var draft = ExpenseDraft(expense: expense)
    for text in ["", "0", "abc", "1.234"] {
      draft.amountText = text
      draft.note = "Changed"
      let updated = try draft.update(
        expense,
        using: service,
        period: period(containing: date),
        now: date
      )
      #expect(!updated)
    }
    #expect(expense.amountCents == 1_000)
    #expect(expense.note == "Coffee")
  }

  @Test("Delete recomputes History and Today, and undo within five seconds restores it")
  func deleteAndUndo() throws {
    let now = calendar.date(2026, 6, 4, 12)
    let food = try category("Food")
    let lunchDate = calendar.date(2026, 6, 2, 12)
    let lunchLogged = calendar.date(2026, 6, 2, 13)
    let lunch = try service.createExpense(
      amountCents: 5_000,
      note: "Lunch",
      date: lunchDate,
      category: food,
      now: lunchLogged
    )
    let coffee = calendar.date(2026, 6, 3, 8)
    try service.createExpense(amountCents: 2_000, note: "Coffee", date: coffee, now: coffee)
    try context.save()
    let before = try history(now: now)
    let todayBefore = try today(now: now)

    let deletion = try ExpenseDeletion.delete(lunch, in: context, now: now)
    #expect(try savedExpenses().map(\.amountCents) == [2_000])
    let deleted = try history(now: now)[0]
    #expect(deleted.spentCents == 2_000)
    #expect(deleted.days.map(\.allowanceCents) == [17_000, 14_000, 11_666, 10_000])
    #expect(try today(now: now).allowanceTodayCents == 17_000)

    let restored = try #require(try deletion.undo(in: context, now: now.addingTimeInterval(4)))
    #expect(restored.amountCents == 5_000)
    #expect(restored.note == "Lunch")
    #expect(restored.date == lunchDate)
    #expect(restored.createdAt == lunchLogged)
    #expect(restored.category === food)
    let reloaded = ModelContext(container)
    #expect(try reloaded.fetchCount(FetchDescriptor<Expense>()) == 2)
    #expect(try history(now: now) == before)
    #expect(try today(now: now) == todayBefore)
  }

  @Test("Undo expires after five seconds and falls back to Other for a deleted category")
  func undoEdges() throws {
    let now = calendar.date(2026, 6, 4, 12)
    let date = calendar.date(2026, 6, 2, 12)
    let shopping = try category("Shopping")
    let first = try service.createExpense(amountCents: 900, date: date, category: shopping)
    let second = try service.createExpense(amountCents: 400, date: date, category: shopping)
    try context.save()

    let expired = try ExpenseDeletion.delete(first, in: context, now: now)
    #expect(try expired.undo(in: context, now: now.addingTimeInterval(5)) == nil)
    #expect(try savedExpenses().map(\.amountCents) == [400])

    let deletion = try ExpenseDeletion.delete(second, in: context, now: now)
    try service.delete(shopping)
    try context.save()
    let restored = try #require(try deletion.undo(in: context, now: now.addingTimeInterval(1)))
    #expect(restored.amountCents == 400)
    #expect(restored.category?.isSystem == true)
  }

  @Test("History screenshots seed two biweekly periods with carryover and some days over")
  func screenshotSeed() throws {
    let now = calendar.date(2026, 6, 10, 12)
    let seedContainer = try RunwayModelContainer.make(inMemory: true)
    let seeded = ModelContext(seedContainer)
    let budget = try #require(
      try ScreenshotScenario.historyList.seed(into: seeded, now: now, calendar: calendar)
    )
    let expenses = try seeded.fetch(FetchDescriptor<Expense>())
    #expect(expenses.count == 36)
    #expect(expenses.allSatisfy { $0.category != nil && $0.date < now })
    #expect(expenses.contains { $0.amountCents < 0 })
    let periods = HistoryEngine(calendar: calendar).periods(
      budget: BudgetSnapshot(budget),
      expenses: expenses.map { HistoryExpense<PersistentIdentifier?>($0) },
      now: now
    )
    #expect(periods.count == 2)
    #expect(periods.map(\.days.count) == [4, 14])
    #expect(periods[1].spentCents == 78_610)
    #expect(periods[1].carryOutCents == 31_390)
    #expect(periods[0].carryInCents == 31_390)
    #expect(periods[1].daysOver > 0)
    #expect(periods[1].categories.count >= 5)
  }
}
