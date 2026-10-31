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

  @Test("Back-to-back deletes keep the first one deleted and undo only the latest")
  func backToBackDeletes() throws {
    let now = calendar.date(2026, 6, 4, 12)
    let lunchDate = calendar.date(2026, 6, 2, 12)
    let busDate = calendar.date(2026, 6, 3, 9)
    let coffeeDate = calendar.date(2026, 6, 3, 8)
    let lunch = try service.createExpense(
      amountCents: 5_000,
      note: "Lunch",
      date: lunchDate,
      category: try category("Food"),
      now: lunchDate
    )
    let bus = try service.createExpense(
      amountCents: 3_000,
      note: "Bus",
      date: busDate,
      category: try category("Transport"),
      now: busDate
    )
    try service.createExpense(amountCents: 2_000, note: "Coffee", date: coffeeDate, now: coffeeDate)
    try context.save()
    let before = try history(now: now)[0]
    #expect(before.spentCents == 10_000)
    #expect(before.days.map(\.spentCents) == [0, 5_000, 5_000, 0])
    #expect(before.days.map(\.allowanceCents) == [15_000, 13_000, 11_666, 10_000])

    var slot = HistoryUndoSlot()
    try slot.delete(lunch, in: context, now: now)
    #expect(slot.pending?.note == "Lunch")
    let afterLunch = try history(now: now)[0]
    #expect(afterLunch.spentCents == 5_000)
    #expect(afterLunch.days.map(\.spentCents) == [0, 5_000, 0, 0])
    #expect(afterLunch.days.map(\.allowanceCents) == [16_250, 14_000, 11_666, 10_000])

    // The second delete replaces the first, which stays deleted in the store.
    try slot.delete(bus, in: context, now: now.addingTimeInterval(1))
    #expect(slot.pending?.note == "Bus")
    let reloaded = ModelContext(container)
    #expect(try reloaded.fetch(FetchDescriptor<Expense>()).map(\.note) == ["Coffee"])
    let afterBus = try history(now: now)[0]
    #expect(afterBus.spentCents == 2_000)
    #expect(afterBus.days.map(\.spentCents) == [0, 2_000, 0, 0])
    #expect(afterBus.days.map(\.allowanceCents) == [17_000, 14_000, 11_666, 10_000])
    #expect(afterBus.categories.map(\.spentCents) == [2_000])

    // Undo restores only the bus fare and empties the slot.
    let restored = try #require(try slot.undo(in: context, now: now.addingTimeInterval(2)))
    #expect(restored.note == "Bus")
    #expect(restored.expense?.category?.name == "Transport")
    #expect(slot.pending == nil)
    #expect(try savedExpenses().map(\.note) == ["Coffee", "Bus"])
    #expect(try history(now: now)[0] == afterLunch)

    // Nothing is left to undo: the lunch can't come back.
    #expect(try slot.undo(in: context, now: now.addingTimeInterval(3)) == nil)
    let fresh = ModelContext(container)
    #expect(try fresh.fetch(FetchDescriptor<Expense>()).map(\.note).sorted() == ["Bus", "Coffee"])
    #expect(try history(now: now)[0] == afterLunch)
    #expect(try today(now: now).allowanceTodayCents == 16_250)
  }

  @Test("Expiry empties the slot only for the deletion it was scheduled for")
  func undoSlotExpiry() throws {
    let now = calendar.date(2026, 6, 4, 12)
    let date = calendar.date(2026, 6, 2, 12)
    let first = try service.createExpense(amountCents: 900, date: date, now: date)
    let second = try service.createExpense(amountCents: 400, date: date, now: date)
    try context.save()

    var slot = HistoryUndoSlot()
    try slot.delete(first, in: context, now: now)
    let firstDeadline = try #require(slot.pending?.expiresAt)
    try slot.delete(second, in: context, now: now.addingTimeInterval(2))
    // The first deletion's timer firing late leaves the second's undo alone.
    slot.expire(at: firstDeadline)
    #expect(slot.pending?.amountCents == 400)
    slot.expire(at: now.addingTimeInterval(7))
    #expect(slot.pending == nil)
    #expect(try savedExpenses().isEmpty)
  }

  /// What `HistoryView` renders from saved expenses, sorted like its query.
  func page(periodOffset: Int = 0, now: Date) throws -> HistoryPage {
    HistoryView.makePage(
      budget: budget,
      expenses: try context.fetch(
        FetchDescriptor<Expense>(
          sortBy: [
            SortDescriptor(\.date, order: .reverse),
            SortDescriptor(\.createdAt, order: .reverse),
          ]
        )
      ),
      periodOffset: periodOffset,
      now: now,
      calendar: calendar
    )
  }

  func editablePeriod(of expense: Expense) -> BudgetPeriod {
    HistoryEngine(calendar: calendar).editablePeriod(
      of: expense.date,
      budget: BudgetSnapshot(budget)
    )
  }

  /// What reached the store, read through a new context.
  func savedInFreshContext() throws -> [(note: String, amountCents: Int, date: Date)] {
    let fresh = ModelContext(container)
    let saved = try fresh.fetch(FetchDescriptor<Expense>())
    return saved.map { ($0.note, $0.amountCents, $0.date) }
  }

  @Test("Moving the start later keeps earlier expenses visible, editable, and deletable")
  func moveStartLater() throws {
    // On the budget's first day no period has been used yet, so the move replaces the schedule.
    let firstDay = calendar.date(2026, 6, 1, 12)
    let coffeeDate = calendar.date(2026, 6, 1, 8)
    let lunchDate = calendar.date(2026, 6, 1, 9)
    let dinnerDate = calendar.date(2026, 6, 1, 10)
    let coffee = try service.createExpense(
      amountCents: 1_000,
      note: "Coffee",
      date: coffeeDate,
      now: coffeeDate
    )
    let lunch = try service.createExpense(
      amountCents: 2_000,
      note: "Lunch",
      date: lunchDate,
      now: lunchDate
    )
    let dinner = try service.createExpense(
      amountCents: 3_000,
      note: "Dinner",
      date: dinnerDate,
      now: dinnerDate
    )
    try context.save()
    #expect(try page(now: firstDay).beforeBudget.isEmpty)

    var budgetDraft = BudgetDraft(budget: budget, locale: Money.fixedLocale)
    budgetDraft.periodStart = calendar.date(2026, 6, 3)
    #expect(budgetDraft.apply(to: budget, now: firstDay, calendar: calendar))
    try context.save()
    #expect(budget.periodStart == calendar.date(2026, 6, 3))
    #expect(budget.scheduleChanges.isEmpty)

    let now = calendar.date(2026, 6, 4, 12)
    let moved = try page(now: now)
    #expect(moved.beforeBudget.map(\.note) == ["Dinner", "Lunch", "Coffee"])
    #expect(moved.selected.spentCents == 0)
    #expect(moved.selected.categories.isEmpty)
    #expect(try today(now: now).allowanceTodayCents == 70_000 / 6)

    // Changing only the amount keeps the date, so it stays out of every period.
    var amountDraft = ExpenseDraft(expense: dinner)
    amountDraft.locale = Money.fixedLocale
    amountDraft.amountText = "35"
    let dinnerPeriod = editablePeriod(of: dinner)
    #expect(dinnerPeriod == .beforeBudget)
    #expect(try amountDraft.update(dinner, using: service, period: dinnerPeriod, now: now))
    try context.save()
    let savedDinner = try #require(try savedInFreshContext().first { $0.note == "Dinner" })
    #expect(savedDinner.amountCents == 3_500)
    #expect(savedDinner.date == dinnerDate)
    let amountEdited = try page(now: now)
    #expect(amountEdited.beforeBudget.map(\.note) == ["Dinner", "Lunch", "Coffee"])
    #expect(amountEdited.selected.spentCents == 0)

    // Choosing a date in the budget moves it into that period.
    var dateDraft = ExpenseDraft(expense: lunch)
    dateDraft.locale = Money.fixedLocale
    dateDraft.date = calendar.date(2026, 6, 3, 14)
    let lunchPeriod = editablePeriod(of: lunch)
    #expect(try dateDraft.update(lunch, using: service, period: lunchPeriod, now: now))
    try context.save()
    let savedLunch = try #require(try savedInFreshContext().first { $0.note == "Lunch" })
    #expect(savedLunch.date == calendar.date(2026, 6, 3, 14))
    let dateEdited = try page(now: now)
    #expect(dateEdited.beforeBudget.map(\.note) == ["Dinner", "Coffee"])
    #expect(dateEdited.selected.spentCents == 2_000)
    #expect(dateEdited.expensesByDay[calendar.date(2026, 6, 3)]?.map(\.note) == ["Lunch"])
    #expect(editablePeriod(of: lunch).start == calendar.date(2026, 6, 3))

    // Delete and undo work as they do for any other expense.
    var slot = HistoryUndoSlot()
    try slot.delete(coffee, in: context, now: now)
    #expect(try savedInFreshContext().map(\.note).sorted() == ["Dinner", "Lunch"])
    #expect(try page(now: now).beforeBudget.map(\.note) == ["Dinner"])
    let restored = try #require(try slot.undo(in: context, now: now.addingTimeInterval(1)))
    #expect(restored.date == coffeeDate)
    #expect(try page(now: now).beforeBudget.map(\.note) == ["Dinner", "Coffee"])
    #expect(try page(now: now).selected.spentCents == 2_000)

    try slot.delete(try #require(restored.expense), in: context, now: now)
    #expect(try savedInFreshContext().map(\.note).sorted() == ["Dinner", "Lunch"])
    #expect(try page(now: now).beforeBudget.map(\.note) == ["Dinner"])
  }

  @Test("Moving the start once the budget has begun leaves earlier expenses in their periods")
  func moveStartAfterBudgetBegan() throws {
    let lunchDate = calendar.date(2026, 6, 1, 12)
    try service.createExpense(amountCents: 2_000, note: "Lunch", date: lunchDate, now: lunchDate)
    try context.save()

    var budgetDraft = BudgetDraft(budget: budget, locale: Money.fixedLocale)
    budgetDraft.periodStart = calendar.date(2026, 6, 5)
    let now = calendar.date(2026, 6, 3, 12)
    #expect(budgetDraft.apply(to: budget, now: now, calendar: calendar))
    try context.save()
    #expect(budget.scheduleChanges.count == 1)

    let oldest = try page(periodOffset: 1, now: now)
    #expect(oldest.beforeBudget.isEmpty)
    #expect(oldest.selected.spentCents == 2_000)
  }

  @Test("The Before budget list shows on the oldest period's page only")
  func beforeBudgetOnOldestPage() throws {
    let date = calendar.date(2026, 5, 30, 9)
    try service.createExpense(amountCents: 1_000, note: "Early", date: date, now: date)
    try context.save()
    let now = calendar.date(2026, 6, 10, 12)
    #expect(try page(periodOffset: 0, now: now).beforeBudget.isEmpty)
    #expect(try page(periodOffset: 1, now: now).beforeBudget.map(\.note) == ["Early"])
    // An offset past the oldest period clamps to it.
    #expect(try page(periodOffset: 5, now: now).beforeBudget.map(\.note) == ["Early"])
  }

  @Test("The before-budget screenshot seeds earlier expenses and money, changing no figures")
  func beforeBudgetScreenshotSeed() throws {
    let now = calendar.date(2026, 6, 10, 12)
    let seedContainer = try RunwayModelContainer.make(inMemory: true)
    let seeded = ModelContext(seedContainer)
    let budget = try #require(
      try ScreenshotScenario.historyBeforeBudget.seed(into: seeded, now: now, calendar: calendar)
    )
    let shown = HistoryView.makePage(
      budget: budget,
      expenses: try seeded.fetch(FetchDescriptor<Expense>()),
      periodOffset: 1,
      now: now,
      calendar: calendar
    )
    #expect(
      shown.beforeBudget.map(\.note) == [
        "Moving truck",
        "Moving-in gift",
        "Returned lamp",
        "Housewarming dinner",
      ]
    )
    #expect(shown.beforeBudget.contains { $0.amountCents < 0 })
    #expect(shown.beforeBudget[1].amountCents == 25_000)
    #expect(shown.periods.map(\.extraCents) == [0, 0])
    // The same figures as `history-list`.
    #expect(shown.periods.map(\.days.count) == [4, 14])
    #expect(shown.periods[1].spentCents == 78_610)
    #expect(shown.periods[1].carryOutCents == 31_390)
  }

  // MARK: - Extra money before the budget

  /// Extra money saved on `date`'s day.
  @discardableResult
  func addExtra(_ cents: Int, note: String, on date: Date) throws -> ExtraMoney {
    let extra = budget.addExtraMoney(cents: cents, note: note, now: date, calendar: calendar)
    try context.save()
    return extra
  }

  func editablePeriod(of extra: ExtraMoney) -> BudgetPeriod {
    HistoryEngine(calendar: calendar).editablePeriod(
      of: extra.date,
      budget: BudgetSnapshot(budget)
    )
  }

  func moneyDraft(_ extra: ExtraMoney) -> ExtraMoneyDraft {
    var draft = ExtraMoneyDraft(extra: extra)
    draft.locale = Money.fixedLocale
    return draft
  }

  /// What reached the store, read through a new context.
  func savedExtrasInFreshContext() throws -> [(note: String, amountCents: Int, date: Date)] {
    let saved = try ModelContext(container).fetch(FetchDescriptor<ExtraMoney>())
    return saved.map { ($0.note, $0.amountCents, $0.date) }
  }

  @Test("Extra money before the start mixes with expenses, newest first, on the oldest page")
  func extraMoneyInBeforeBudget() throws {
    let truck = calendar.date(2026, 5, 30, 18)
    let lamp = calendar.date(2026, 5, 26, 18)
    try service.createExpense(amountCents: 1_000, note: "Truck", date: truck, now: truck)
    try service.createExpense(amountCents: 2_000, note: "Lamp", date: lamp, now: lamp)
    try addExtra(25_000, note: "Gift", on: calendar.date(2026, 5, 28, 9))
    // On the first day, so in a period and not listed.
    try addExtra(5_000, note: "Bonus", on: calendar.date(2026, 6, 1, 9))
    try context.save()

    let now = calendar.date(2026, 6, 10, 12)
    #expect(try page(periodOffset: 0, now: now).beforeBudget.isEmpty)
    let oldest = try page(periodOffset: 1, now: now)
    #expect(oldest.beforeBudget.map(\.note) == ["Truck", "Gift", "Lamp"])
    let gift = oldest.beforeBudget[1]
    guard case .extraMoney(let extra) = gift else {
      Issue.record("Expected extra money")
      return
    }
    #expect(extra.amountCents == 25_000)
    #expect(gift.id == extra.persistentModelID)
    #expect(gift.date == calendar.date(2026, 5, 28))
  }

  @Test("Same-day extra money before the start keeps a fixed order")
  func extraMoneySameDayOrder() throws {
    let day = calendar.date(2026, 5, 28, 9)
    try addExtra(300, note: "Cake", on: day)
    try addExtra(200, note: "Apple", on: day)
    try addExtra(100, note: "Apple", on: day)
    let shown = try page(now: calendar.date(2026, 6, 3, 12)).beforeBudget
    #expect(shown.map(\.note) == ["Apple", "Apple", "Cake"])
    #expect(shown.map(\.amountCents) == [100, 200, 300])
  }

  @Test("Extra money before the start counts toward no period, carryover, or Today")
  func extraMoneyBeforeStartExcluded() throws {
    let now = calendar.date(2026, 6, 10, 12)
    let baseline = try history(now: now)
    let todayBaseline = try today(now: now)

    // The last moment before the first day.
    let extra = try addExtra(25_000, note: "Gift", on: calendar.date(2026, 5, 31))
    extra.date = calendar.date(2026, 5, 31, 23, 59, 59)
    try context.save()

    #expect(try history(now: now) == baseline)
    #expect(try today(now: now) == todayBaseline)
    let oldest = try #require(baseline.last)
    #expect(oldest.extraCents == 0)
    #expect(oldest.carryOutCents == 70_000)
    #expect(baseline.first?.carryInCents == 70_000)

    // The preview of the first period, before the budget's first day, ignores it too.
    let preview = AllowanceEngine(calendar: calendar).currentAllowance(
      budget: BudgetSnapshot(budget),
      expenses: [],
      now: calendar.date(2026, 5, 20, 12)
    )
    #expect(preview.extraCents == 0)
    #expect(preview.remainingPeriodCents == 70_000)

    // The first day itself counts.
    extra.date = calendar.date(2026, 6, 1)
    try context.save()
    let moved = try history(now: now)
    #expect(moved.last?.extraCents == 25_000)
    #expect(moved.last?.carryOutCents == 95_000)
  }

  @Test("Moving the start later moves extra money into Before budget and out of the figures")
  func moveStartLaterMovesExtraMoney() throws {
    // On the budget's first day no period has been used yet, so the move replaces the schedule.
    let firstDay = calendar.date(2026, 6, 1, 12)
    try addExtra(25_000, note: "Gift", on: firstDay)
    let later = calendar.date(2026, 6, 11, 12)

    let before = try page(periodOffset: 1, now: later)
    #expect(before.beforeBudget.isEmpty)
    #expect(before.selected.extraCents == 25_000)
    #expect(before.selected.carryOutCents == 95_000)
    #expect(try today(now: later).carryInCents == 95_000)

    var budgetDraft = BudgetDraft(budget: budget, locale: Money.fixedLocale)
    budgetDraft.periodStart = calendar.date(2026, 6, 3)
    #expect(budgetDraft.apply(to: budget, now: firstDay, calendar: calendar))
    try context.save()
    #expect(budget.periodStart == calendar.date(2026, 6, 3))
    #expect(budget.scheduleChanges.isEmpty)

    let after = try page(periodOffset: 1, now: later)
    #expect(after.beforeBudget.map(\.note) == ["Gift"])
    #expect(after.periods.map(\.extraCents) == [0, 0])
    #expect(after.selected.carryOutCents == 70_000)
    let result = try today(now: later)
    #expect(result.extraCents == 0)
    #expect(result.carryInCents == 70_000)
  }

  @Test("Moving the start once the budget has begun leaves extra money in its period")
  func moveStartAfterBudgetBeganKeepsExtraMoney() throws {
    try addExtra(25_000, note: "Gift", on: calendar.date(2026, 6, 1, 12))
    var budgetDraft = BudgetDraft(budget: budget, locale: Money.fixedLocale)
    budgetDraft.periodStart = calendar.date(2026, 6, 5)
    let now = calendar.date(2026, 6, 3, 12)
    #expect(budgetDraft.apply(to: budget, now: now, calendar: calendar))
    try context.save()
    #expect(budget.scheduleChanges.count == 1)

    let oldest = try page(periodOffset: 1, now: now)
    #expect(oldest.beforeBudget.isEmpty)
    #expect(oldest.selected.extraCents == 25_000)
  }

  @Test("Editing extra money before the start keeps its date unless another is chosen")
  func editExtraMoneyBeforeStart() throws {
    let originalDate = calendar.date(2026, 5, 28)
    let extra = try addExtra(25_000, note: "Gift", on: originalDate)
    let now = calendar.date(2026, 6, 10, 12)
    let period = editablePeriod(of: extra)
    #expect(period == .beforeBudget)

    var draft = moneyDraft(extra)
    #expect(draft.amountCents == 25_000)
    #expect(draft.note == "Gift")
    #expect(draft.date == originalDate)
    draft.amountText = "300.50"
    draft.note = "  Bigger gift "
    #expect(draft.update(extra, period: period, now: now, calendar: calendar))
    try context.save()
    let saved = try #require(try savedExtrasInFreshContext().first)
    #expect(saved.note == "Bigger gift")
    #expect(saved.amountCents == 30_050)
    #expect(saved.date == originalDate)
    let edited = try page(periodOffset: 1, now: now)
    #expect(edited.beforeBudget.map(\.note) == ["Bigger gift"])
    #expect(edited.selected.extraCents == 0)

    // Another day before the start stays out of every period, at local midnight.
    var earlier = moneyDraft(extra)
    earlier.date = calendar.date(2026, 5, 20, 15)
    #expect(earlier.update(extra, period: period, now: now, calendar: calendar))
    #expect(extra.date == calendar.date(2026, 5, 20))
    #expect(editablePeriod(of: extra) == .beforeBudget)

    // A day in the budget moves it into that period and out of the section.
    var moved = moneyDraft(extra)
    moved.date = calendar.date(2026, 6, 3, 15)
    #expect(moved.update(extra, period: period, now: now, calendar: calendar))
    try context.save()
    #expect(extra.date == calendar.date(2026, 6, 3))
    let shown = try page(periodOffset: 1, now: now)
    #expect(shown.beforeBudget.isEmpty)
    #expect(shown.selected.extraCents == 30_050)
    #expect(shown.selected.carryOutCents == 100_050)

    // Never after now.
    var future = moneyDraft(extra)
    future.date = calendar.date(2026, 6, 12)
    let clamped = future.savedDate(in: period, now: now, calendar: calendar)
    #expect(clamped == calendar.date(2026, 6, 10))
  }

  @Test("An unchanged date is saved as it was, whatever its time or how it compares to now")
  func extraMoneyUnchangedDateIsExact() throws {
    let extra = try addExtra(1_000, note: "Imported", on: calendar.date(2026, 5, 28))
    let imported = calendar.date(2026, 5, 28, 15)
    extra.date = imported
    let draft = moneyDraft(extra)
    let now = calendar.date(2026, 5, 20, 12)
    #expect(draft.savedDate(in: .beforeBudget, now: now, calendar: calendar) == imported)
  }

  @Test("Invalid extra money amounts change nothing, and a negative amount stays negative")
  func extraMoneyAmounts() throws {
    let date = calendar.date(2026, 5, 28)
    let extra = try addExtra(25_000, note: "Gift", on: date)
    let now = calendar.date(2026, 6, 10, 12)
    for text in ["", "0", "abc"] {
      var draft = moneyDraft(extra)
      draft.amountText = text
      draft.note = "Changed"
      draft.date = calendar.date(2026, 5, 20)
      #expect(draft.amountCents == nil)
      #expect(!draft.update(extra, period: .beforeBudget, now: now, calendar: calendar))
      #expect(extra.amountCents == 25_000)
      #expect(extra.note == "Gift")
      #expect(extra.date == date)
    }

    extra.amountCents = -1_250
    var negative = moneyDraft(extra)
    #expect(negative.amountCents == -1_250)
    negative.amountText = "20"
    #expect(negative.update(extra, period: .beforeBudget, now: now, calendar: calendar))
    #expect(extra.amountCents == -2_000)
  }

  @Test("Deleting extra money before the start removes it from the section and the store")
  func deleteExtraMoneyBeforeStart() throws {
    let gift = try addExtra(25_000, note: "Gift", on: calendar.date(2026, 5, 28))
    try addExtra(1_000, note: "Refund", on: calendar.date(2026, 5, 27))
    let now = calendar.date(2026, 6, 3, 12)
    #expect(try page(now: now).beforeBudget.map(\.note) == ["Gift", "Refund"])

    budget.removeExtraMoney(gift)
    try context.save()

    #expect(try page(now: now).beforeBudget.map(\.note) == ["Refund"])
    #expect(try savedExtrasInFreshContext().map(\.note) == ["Refund"])
  }

  // MARK: - Extra money in periods

  @Test("Past and current pages list extra money by day, apart from spending")
  func extraMoneyRowsByDay() throws {
    let lunch = calendar.date(2026, 6, 3, 12)
    try service.createExpense(amountCents: 2_000, note: "Lunch", date: lunch, now: lunch)
    try addExtra(25_000, note: "Gift", on: calendar.date(2026, 6, 3))
    try addExtra(1_000, note: "Cashback", on: calendar.date(2026, 6, 3))
    try addExtra(5_000, note: "Bonus", on: calendar.date(2026, 6, 9))
    try addExtra(9_000, note: "Early", on: calendar.date(2026, 5, 28))
    let now = calendar.date(2026, 6, 10, 12)

    let past = try page(periodOffset: 1, now: now)
    let day = calendar.date(2026, 6, 3)
    #expect(past.extraMoneyByDay.count == 1)
    #expect(past.extraMoneyByDay[day]?.map(\.note) == ["Cashback", "Gift"])
    #expect(past.expensesByDay[day]?.map(\.note) == ["Lunch"])
    let row = try #require(past.selected.days.first { $0.date == day })
    #expect(row.spentCents == 2_000)
    #expect(row.allowanceCents == (70_000 + 26_000) / 5)
    #expect(past.selected.spentCents == 2_000)
    #expect(past.selected.extraCents == 26_000)
    #expect(past.selected.categories.map(\.spentCents) == [2_000])
    #expect(past.selected.carryOutCents == 94_000)

    let current = try page(periodOffset: 0, now: now)
    #expect(current.extraMoneyByDay[calendar.date(2026, 6, 9)]?.map(\.note) == ["Bonus"])
    #expect(current.extraMoneyByDay.count == 1)
  }

  @Test("Editing a past period's extra money keeps it in that period and updates its figures")
  func editExtraMoneyInPastPeriod() throws {
    let extra = try addExtra(25_000, note: "Gift", on: calendar.date(2026, 6, 3))
    let now = calendar.date(2026, 6, 10, 12)
    let period = editablePeriod(of: extra)
    #expect(period.start == calendar.date(2026, 6, 1))

    var draft = moneyDraft(extra)
    draft.amountText = "100"
    // A date after its period clamps to the period's last day.
    draft.date = now
    #expect(draft.update(extra, period: period, now: now, calendar: calendar))
    try context.save()
    #expect(extra.date == calendar.date(2026, 6, 7))
    let shown = try page(periodOffset: 1, now: now)
    #expect(shown.extraMoneyByDay[calendar.date(2026, 6, 7)]?.map(\.amountCents) == [10_000])
    #expect(shown.selected.carryOutCents == 80_000)
  }

  @Test("Undo restores deleted extra money's amount, sign, note, and exact date, and the figures")
  func deleteAndUndoExtraMoney() throws {
    let extra = try addExtra(-4_250, note: "Bank correction", on: calendar.date(2026, 6, 3))
    let imported = calendar.date(2026, 6, 3, 15)
    extra.date = imported
    try context.save()
    let now = calendar.date(2026, 6, 10, 12)
    let before = try history(now: now)
    let todayBefore = try today(now: now)
    #expect(before[1].extraCents == -4_250)

    var slot = HistoryUndoSlot()
    try slot.delete(extra, from: budget, in: context, now: now)
    #expect(try savedExtrasInFreshContext().isEmpty)
    #expect(budget.extraMoney.isEmpty)
    #expect(try history(now: now)[1].extraCents == 0)

    let restored = try #require(try slot.undo(in: context, now: now.addingTimeInterval(4)))
    #expect(slot.pending == nil)
    guard case .extraMoney(let money) = restored else {
      Issue.record("Expected extra money")
      return
    }
    #expect(money.budget === budget)
    let saved = try #require(try savedExtrasInFreshContext().first)
    #expect(saved.amountCents == -4_250)
    #expect(saved.note == "Bank correction")
    #expect(saved.date == imported)
    #expect(try history(now: now) == before)
    #expect(try today(now: now) == todayBefore)
  }

  @Test("Undo of extra money expires after five seconds, leaving it deleted")
  func extraMoneyUndoExpires() throws {
    let extra = try addExtra(1_000, note: "Gift", on: calendar.date(2026, 6, 3))
    let now = calendar.date(2026, 6, 10, 12)
    var slot = HistoryUndoSlot()
    try slot.delete(extra, from: budget, in: context, now: now)
    #expect(slot.pending?.expiresAt == now.addingTimeInterval(5))
    #expect(try slot.undo(in: context, now: now.addingTimeInterval(5)) == nil)
    #expect(slot.pending == nil)
    #expect(try savedExtrasInFreshContext().isEmpty)
  }

  @Test("A new delete of either kind replaces the pending undo")
  func undoSlotAcrossKinds() throws {
    let date = calendar.date(2026, 6, 3, 12)
    let now = calendar.date(2026, 6, 10, 12)
    let lunch = try service.createExpense(amountCents: 2_000, note: "Lunch", date: date, now: date)
    let bus = try service.createExpense(amountCents: 300, note: "Bus", date: date, now: date)
    let gift = try addExtra(25_000, note: "Gift", on: date)
    try context.save()

    // Money replaces an expense: only the money comes back.
    var slot = HistoryUndoSlot()
    try slot.delete(lunch, in: context, now: now)
    try slot.delete(gift, from: budget, in: context, now: now)
    let money = try #require(try slot.undo(in: context, now: now))
    #expect(money.note == "Gift")
    #expect(money.expense == nil)
    #expect(try savedExpenses().map(\.note) == ["Bus"])
    #expect(try savedExtrasInFreshContext().map(\.note) == ["Gift"])

    // An expense replaces money: only the expense comes back.
    guard case .extraMoney(let restoredGift) = money else {
      Issue.record("Expected extra money")
      return
    }
    try slot.delete(restoredGift, from: budget, in: context, now: now)
    try slot.delete(bus, in: context, now: now)
    let expense = try #require(try slot.undo(in: context, now: now))
    #expect(expense.expense?.note == "Bus")
    #expect(try savedExpenses().map(\.note) == ["Bus"])
    #expect(try savedExtrasInFreshContext().isEmpty)
    #expect(try slot.undo(in: context, now: now) == nil)
  }

  @Test("The sign control shows the saved sign and can keep or flip it")
  func extraMoneySign() throws {
    let date = calendar.date(2026, 6, 3)
    let now = calendar.date(2026, 6, 10, 12)
    let positive = try addExtra(25_000, note: "Gift", on: date)
    let negative = try addExtra(-1_250, note: "Correction", on: date)

    var addedDraft = moneyDraft(positive)
    #expect(!addedDraft.isNegative)
    #expect(addedDraft.amountCents == 25_000)
    var removedDraft = moneyDraft(negative)
    #expect(removedDraft.isNegative)
    #expect(removedDraft.amountText == "$12.50")
    #expect(removedDraft.amountCents == -1_250)

    // Kept negative through a save.
    let period = editablePeriod(of: negative)
    removedDraft.note = "Fee"
    #expect(removedDraft.update(negative, period: period, now: now, calendar: calendar))
    #expect(negative.amountCents == -1_250)

    // Flipped both ways.
    removedDraft.isNegative = false
    #expect(removedDraft.update(negative, period: period, now: now, calendar: calendar))
    #expect(negative.amountCents == 1_250)
    addedDraft.isNegative = true
    #expect(addedDraft.update(positive, period: period, now: now, calendar: calendar))
    #expect(positive.amountCents == -25_000)

    // An invalid amount changes nothing, whichever the sign.
    addedDraft.amountText = "0"
    addedDraft.isNegative = false
    #expect(!addedDraft.update(positive, period: period, now: now, calendar: calendar))
    #expect(positive.amountCents == -25_000)
  }

  @Test("The extra money screenshots seed a row among expenses and a negative amount")
  func extraMoneyScreenshotSeeds() throws {
    let now = calendar.date(2026, 6, 10, 12)
    let lastDay = calendar.date(2026, 6, 6)

    let rowContainer = try RunwayModelContainer.make(inMemory: true)
    let rowContext = ModelContext(rowContainer)
    let rowBudget = try #require(
      try ScreenshotScenario.historyExtraMoney.seed(into: rowContext, now: now, calendar: calendar)
    )
    let shown = HistoryView.makePage(
      budget: rowBudget,
      expenses: try rowContext.fetch(FetchDescriptor<Expense>()),
      periodOffset: 1,
      now: now,
      calendar: calendar
    )
    #expect(shown.extraMoneyByDay.count == 1)
    #expect(shown.extraMoneyByDay[lastDay]?.map(\.note) == ["Birthday gift"])
    #expect(shown.expensesByDay[lastDay]?.count == 2)
    #expect(shown.selected.spentCents == 78_610)
    #expect(shown.selected.extraCents == 15_000)
    #expect(shown.selected.carryOutCents == 46_390)

    let editContainer = try RunwayModelContainer.make(inMemory: true)
    let editContext = ModelContext(editContainer)
    let editBudget = try #require(
      try ScreenshotScenario.extraMoneyEditNegative.seed(
        into: editContext,
        now: now,
        calendar: calendar
      )
    )
    let negative = try #require(editBudget.extraMoney.first)
    #expect(negative.date == lastDay)
    #expect(negative.amountCents == -4_250)
    #expect(ExtraMoneyDraft(extra: negative).isNegative)
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

  /// `HistoryEngineTests.manyExpenses` times the engine on plain values; this times what
  /// `HistoryView` computes per render from saved expenses, as the `history-500` scenario shows.
  @Test("History-500 seeds 500 expenses in one period and History's page builds quickly")
  func fiveHundredExpensePage() throws {
    let now = calendar.date(2026, 6, 10, 12)
    let seedContainer = try RunwayModelContainer.make(inMemory: true)
    let seeded = ModelContext(seedContainer)
    let budget = try #require(
      try ScreenshotScenario.history500.seed(into: seeded, now: now, calendar: calendar)
    )
    // Sorted like HistoryView's query.
    let expenses = try seeded.fetch(
      FetchDescriptor<Expense>(
        sortBy: [
          SortDescriptor(\.date, order: .reverse),
          SortDescriptor(\.createdAt, order: .reverse),
        ]
      )
    )
    #expect(expenses.count == 500)

    var page: HistoryPage?
    let elapsed = ContinuousClock().measure {
      page = HistoryView.makePage(
        budget: budget,
        expenses: expenses,
        periodOffset: 1,
        now: now,
        calendar: calendar
      )
    }
    #expect(elapsed < .seconds(1))
    let shown = try #require(page)
    #expect(shown.periods.map(\.days.count) == [4, 14])
    #expect(shown.periods[0].spentCents == 0)
    #expect(shown.selected.spentCents == 1_354_120)
    #expect(shown.expensesByDay.count == 14)
    #expect(shown.expensesByDay.values.reduce(0) { $0 + $1.count } == 500)
    // Each day's rows add up to its day row and stay newest first.
    for day in shown.selected.days {
      let rows = shown.expensesByDay[day.date] ?? []
      #expect(rows.reduce(0) { $0 + $1.amountCents } == day.spentCents)
      #expect(rows.map(\.date) == rows.map(\.date).sorted(by: >))
    }
  }

  /// Times what `HistoryView` computes per render for a long period chain, and logs it for CI so
  /// LIB-464 can decide whether the chain needs caching (threshold about 100 ms).
  @Test("History's page builds quickly for 24+ periods with budget changes")
  func longPeriodChainPage() throws {
    let start = calendar.date(2026, 1, 5)
    let now = calendar.date(2026, 6, 30, 12)
    let longBudget = Budget(
      periodLength: .weekly,
      periodStart: start,
      spendablePerPeriodCents: 70_000
    )
    context.insert(longBudget)
    longBudget.updatePeriod(
      .weekly,
      start: calendar.date(2026, 3, 4),
      now: calendar.date(2026, 3, 4, 12),
      calendar: calendar
    )
    longBudget.spendablePerPeriodCents = 80_000
    longBudget.recordAmountChange(
      from: 70_000,
      now: calendar.date(2026, 4, 15, 12),
      calendar: calendar
    )
    longBudget.spendablePerPeriodCents = 75_000
    longBudget.recordAmountChange(
      from: 80_000,
      now: calendar.date(2026, 5, 20, 12),
      calendar: calendar
    )
    var totalCents = 0
    for index in 0..<400 {
      let day = calendar.date(byAdding: .day, value: index * 176 / 400, to: start)!
      let date = calendar.date(byAdding: .minute, value: 480 + index % 20 * 30, to: day)!
      let amountCents = 500 + index % 37 * 150
      totalCents += amountCents
      try service.createExpense(amountCents: amountCents, date: date, now: date)
    }
    try context.save()
    #expect(longBudget.scheduleChanges.count == 1)
    #expect(longBudget.amountChanges.count == 2)
    // Sorted like HistoryView's query.
    let expenses = try context.fetch(
      FetchDescriptor<Expense>(
        sortBy: [
          SortDescriptor(\.date, order: .reverse),
          SortDescriptor(\.createdAt, order: .reverse),
        ]
      )
    )
    #expect(expenses.count == 400)

    var page: HistoryPage?
    let elapsed = ContinuousClock().measure {
      page = HistoryView.makePage(
        budget: longBudget,
        expenses: expenses,
        periodOffset: 0,
        now: now,
        calendar: calendar
      )
    }
    let parts = elapsed.components
    let milliseconds = Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    print("LIB464_HISTORY_LOAD_MS=\(String(format: "%.2f", milliseconds))")

    #expect(elapsed < .seconds(1))
    let shown = try #require(page)
    #expect(shown.periods.count >= 24)
    #expect(shown.periods.reduce(0) { $0 + $1.spentCents } == totalCents)
  }
}

extension HistoryItem {
  fileprivate var expense: Expense? {
    if case .expense(let expense) = self { return expense }
    return nil
  }
}

extension HistoryDeletion {
  fileprivate var note: String {
    switch self {
    case .expense(let deletion): deletion.note
    case .extraMoney(let deletion): deletion.note
    }
  }

  fileprivate var amountCents: Int {
    switch self {
    case .expense(let deletion): deletion.amountCents
    case .extraMoney(let deletion): deletion.amountCents
    }
  }
}
