import Foundation
import SwiftData
import Testing

@testable import Runway

/// Amount edits, extra money, and bill marks mid-period. Weekly budget anchored Monday 2026-06-01
/// in Chicago with $700 available; "today" is Wednesday Jun 3, so 5 days are left (Jun 3–7).
struct MidPeriodAmountTests {
  let calendar = Calendar.gregorian("America/Chicago")
  let container: ModelContainer

  init() throws {
    container = try RunwayModelContainer.make(inMemory: true)
  }

  var engine: AllowanceEngine { AllowanceEngine(calendar: calendar) }

  var today: Date { calendar.date(2026, 6, 3, 12) }

  /// $100 spent on Monday.
  var mondayLunch: [ExpenseSnapshot] { [expense(10_000, calendar.date(2026, 6, 1, 12))] }

  /// $700 available a week: spendable $700, or $1,000 minus a $300 Rent bill when `withRent`.
  func makeBudget(in context: ModelContext, withRent: Bool = false) throws -> Budget {
    let budget = Budget(
      periodLength: .weekly,
      periodStart: calendar.date(2026, 6, 1),
      spendablePerPeriodCents: withRent ? 100_000 : 70_000
    )
    context.insert(budget)
    if withRent {
      let rent = FixedBill(name: "Rent", amountCents: 30_000, dueDay: 1)
      context.insert(rent)
      budget.fixedBills.append(rent)
    }
    try context.save()
    return budget
  }

  func allowance(_ budget: Budget, now: Date, expenses: [ExpenseSnapshot]) -> AllowanceResult {
    engine.currentAllowance(budget: BudgetSnapshot(budget), expenses: expenses, now: now)
  }

  /// History for `budget` with Monday's lunch, newest period first.
  func historyPeriods(_ budget: Budget, now: Date) -> [HistoryPeriod<String>] {
    let expenses = mondayLunch.map { historyExpense($0.amountCents, $0.date) }
    return HistoryEngine(calendar: calendar).periods(
      budget: BudgetSnapshot(budget),
      expenses: expenses,
      now: now
    )
  }

  /// History's day allowances in the current period, oldest first.
  func dayAllowances(_ budget: Budget, now: Date) -> [Int] {
    historyPeriods(budget, now: now)[0].days.reversed().map(\.allowanceCents)
  }

  // MARK: - Amount changes

  @Test("Raising spendable mid-period applies from today and keeps earlier days' allowances")
  func raiseSpendable() throws {
    let context = ModelContext(container)
    let budget = try makeBudget(in: context)
    // (700 - 100) / 5 days left.
    #expect(allowance(budget, now: today, expenses: mondayLunch).allowanceTodayCents == 12_000)
    #expect(dayAllowances(budget, now: today) == [10_000, 10_000, 12_000])

    var draft = BudgetDraft(budget: budget, locale: Money.fixedLocale)
    draft.spendableText = "1,050"
    #expect(draft.changesAvailable(of: budget))
    #expect(draft.apply(to: budget, now: today, calendar: calendar))
    try context.save()

    let changes = try context.fetch(FetchDescriptor<AmountChange>())
    #expect(changes.count == 1)
    #expect(changes.first?.previousAvailableCents == 70_000)
    #expect(changes.first?.effectiveAt == calendar.date(2026, 6, 3))
    #expect(changes.first?.budget?.persistentModelID == budget.persistentModelID)

    // (1,050 - 100) / 5. Monday and Tuesday keep what they had.
    let result = allowance(budget, now: today, expenses: mondayLunch)
    #expect(result.allowanceTodayCents == 19_000)
    #expect(result.remainingPeriodCents == 95_000)
    #expect(dayAllowances(budget, now: today) == [10_000, 10_000, 19_000])
  }

  @Test("Bill and savings edits on the same day share one change, and undoing them drops it")
  func sameDayEdits() throws {
    let context = ModelContext(container)
    let budget = try makeBudget(in: context)

    var draft = BudgetDraft(budget: budget, locale: Money.fixedLocale)
    draft.bills.append(BudgetDraft.Bill(name: "Gym", amountText: "100"))
    #expect(draft.apply(to: budget, now: today, calendar: calendar))
    draft = BudgetDraft(budget: budget, locale: Money.fixedLocale)
    draft.savingsText = "50"
    #expect(draft.apply(to: budget, now: calendar.date(2026, 6, 3, 18), calendar: calendar))
    try context.save()

    #expect(budget.availablePerPeriodCents == 55_000)
    #expect(budget.amountChanges.map(\.previousAvailableCents) == [70_000])
    // (550 - 100) / 5.
    #expect(allowance(budget, now: today, expenses: mondayLunch).allowanceTodayCents == 9_000)

    draft = BudgetDraft(budget: budget, locale: Money.fixedLocale)
    draft.bills.removeAll()
    draft.savingsText = ""
    #expect(draft.apply(to: budget, now: calendar.date(2026, 6, 3, 20), calendar: calendar))
    try context.save()

    #expect(budget.amountChanges.isEmpty)
    #expect(try context.fetchCount(FetchDescriptor<AmountChange>()) == 0)
    #expect(allowance(budget, now: today, expenses: mondayLunch).allowanceTodayCents == 12_000)
  }

  @Test("Amount edits before the budget's first day aren't recorded")
  func editBeforeStart() throws {
    let context = ModelContext(container)
    let budget = try makeBudget(in: context)
    var draft = BudgetDraft(budget: budget, locale: Money.fixedLocale)
    draft.spendableText = "1050"
    #expect(draft.apply(to: budget, now: calendar.date(2026, 5, 30, 12), calendar: calendar))
    try context.save()

    #expect(budget.amountChanges.isEmpty)
    let monday = calendar.date(2026, 6, 1, 9)
    #expect(allowance(budget, now: monday, expenses: []).allowanceTodayCents == 15_000)
  }

  @Test("A completed period's carry-out uses the amount in effect on its last day")
  func carryOutUsesLatestAmount() {
    let budget = BudgetSnapshot(
      periodLength: .weekly,
      periodStart: calendar.date(2026, 6, 1),
      spendablePerPeriodCents: 35_000,
      amountChanges: [
        AmountChangeSnapshot(previousCents: 70_000, effectiveAt: calendar.date(2026, 6, 4))
      ]
    )
    #expect(budget.availableCents(on: calendar.date(2026, 6, 3)) == 70_000)
    #expect(budget.availableCents(on: calendar.date(2026, 6, 4)) == 35_000)

    let result = engine.currentAllowance(
      budget: budget,
      expenses: mondayLunch,
      now: calendar.date(2026, 6, 8, 9)
    )
    // 350 - 100 carried in, plus 350 for the new week, over 7 days.
    #expect(result.carryInCents == 25_000)
    #expect(result.allowanceTodayCents == 8_571)
  }

  // MARK: - Extra money

  @Test("Extra money raises today's allowance and the remainder, never earlier days")
  func addsExtraMoney() throws {
    let context = ModelContext(container)
    let budget = try makeBudget(in: context)
    let gift = budget.addExtraMoney(cents: 15_000, note: " Birthday gift ", now: today)
    try context.save()

    #expect(gift.note == "Birthday gift")
    #expect(gift.budget?.persistentModelID == budget.persistentModelID)
    let result = allowance(budget, now: today, expenses: mondayLunch)
    // (700 + 150 - 100) / 5.
    #expect(result.allowanceTodayCents == 15_000)
    #expect(result.remainingPeriodCents == 75_000)
    #expect(result.extraCents == 15_000)
    #expect(dayAllowances(budget, now: today) == [10_000, 10_000, 15_000])
    let current = historyPeriods(budget, now: today)[0]
    #expect(current.extraCents == 15_000)
    #expect(current.availableCents == 85_000)
    #expect(budget.extraMoneyItems(in: result.period).map(\.note) == ["Birthday gift"])

    // It carries out like any leftover: 700 + 150 - 100.
    let monday = calendar.date(2026, 6, 8, 9)
    #expect(allowance(budget, now: monday, expenses: mondayLunch).carryInCents == 75_000)

    budget.removeExtraMoney(gift)
    try context.save()
    #expect(try context.fetchCount(FetchDescriptor<ExtraMoney>()) == 0)
    #expect(allowance(budget, now: today, expenses: mondayLunch).allowanceTodayCents == 12_000)
  }

  @Test("Extra money dated later counts from its own day")
  func futureExtraMoney() {
    let budget = BudgetSnapshot(
      periodLength: .weekly,
      periodStart: calendar.date(2026, 6, 1),
      spendablePerPeriodCents: 70_000,
      extraMoney: [ExtraMoneySnapshot(amountCents: 10_000, date: calendar.date(2026, 6, 5, 9))]
    )
    let wednesday = engine.currentAllowance(budget: budget, expenses: [], now: today)
    #expect(wednesday.remainingPeriodCents == 70_000)
    #expect(wednesday.extraCents == 0)
    // Friday: (700 + 100) / 3.
    let friday = engine.currentAllowance(
      budget: budget,
      expenses: [],
      now: calendar.date(2026, 6, 5, 12)
    )
    #expect(friday.allowanceTodayCents == 26_666)
    #expect(friday.remainingPeriodCents == 80_000)
  }

  // MARK: - Bills

  @Test("Skipping a bill or paying another amount adjusts the remainder from today")
  func billMarks() throws {
    let context = ModelContext(container)
    let budget = try makeBudget(in: context, withRent: true)
    let rent = try #require(budget.fixedBills.first)
    let period = engine.period(containing: today, of: BudgetSnapshot(budget))
    func current() -> AllowanceResult {
      allowance(budget, now: today, expenses: [])
    }
    #expect(budget.status(of: rent, in: period) == .unpaid)
    #expect(current().remainingPeriodCents == 70_000)

    // Bills are set aside every period, so paying early as planned changes nothing.
    budget.setStatus(.paid(cents: 30_000), of: rent, now: today, calendar: calendar)
    #expect(budget.status(of: rent, in: period) == .paid(cents: 30_000))
    #expect(current().remainingPeriodCents == 70_000)

    budget.setStatus(.paid(cents: 25_000), of: rent, now: today, calendar: calendar)
    #expect(current().remainingPeriodCents == 75_000)

    budget.setStatus(.skipped, of: rent, now: today, calendar: calendar)
    try context.save()
    #expect(budget.status(of: rent, in: period) == .skipped)
    #expect(try context.fetchCount(FetchDescriptor<BillPayment>()) == 3)
    #expect(current().remainingPeriodCents == 100_000)
    // 1,000 / 5 from today. Monday and Tuesday keep 700 / 7.
    #expect(current().allowanceTodayCents == 20_000)
    let days = HistoryEngine(calendar: calendar).periods(
      budget: BudgetSnapshot(budget),
      expenses: [HistoryExpense<String>](),
      now: today
    )[0].days
    #expect(days.reversed().map(\.allowanceCents) == [10_000, 10_000, 20_000])

    // The skipped money carries out like any leftover, and the next period sets Rent aside.
    let next = allowance(budget, now: calendar.date(2026, 6, 8, 9), expenses: [])
    #expect(next.carryInCents == 100_000)
    #expect(budget.status(of: rent, in: next.period) == .unpaid)

    budget.setStatus(.unpaid, of: rent, now: today, calendar: calendar)
    try context.save()
    #expect(try context.fetchCount(FetchDescriptor<BillPayment>()) == 4)
    #expect(current().remainingPeriodCents == 70_000)
  }

  @Test("Editing or removing a bill marked this period keeps the period's total right")
  func editMarkedBill() throws {
    // Rent is marked on Wednesday, then removed or cut to $200 on Thursday. Skipped, the period
    // has all 1,000; paid at 250, it has 1,000 - 250.
    let cases: [(status: BillStatus, newAmountCents: Int?, expectedCents: Int)] = [
      (.skipped, nil, 100_000),
      (.paid(cents: 25_000), nil, 75_000),
      (.skipped, 20_000, 100_000),
      (.paid(cents: 25_000), 20_000, 75_000),
    ]
    for (status, newAmountCents, expectedCents) in cases {
      let container = try RunwayModelContainer.make(inMemory: true)
      let context = ModelContext(container)
      let budget = try makeBudget(in: context, withRent: true)
      let rent = try #require(budget.fixedBills.first)
      budget.setStatus(status, of: rent, now: today, calendar: calendar)
      try context.save()

      let thursday = calendar.date(2026, 6, 4, 12)
      var draft = BudgetDraft(budget: budget, locale: Money.fixedLocale)
      if let newAmountCents {
        draft.bills[0].amountText = BudgetDraft.text(fromCents: newAmountCents)
      } else {
        draft.bills.removeAll()
      }
      #expect(draft.apply(to: budget, now: thursday, calendar: calendar))
      try context.save()

      let wednesday = allowance(budget, now: today, expenses: [])
      let markedCents = status == .skipped ? 100_000 : 75_000
      #expect(wednesday.remainingPeriodCents == markedCents)
      let result = allowance(budget, now: thursday, expenses: [])
      #expect(result.remainingPeriodCents == expectedCents, "\(status) \(newAmountCents ?? 0)")
      // Next period, only the bill as it is now is set aside.
      let next = allowance(budget, now: calendar.date(2026, 6, 8, 9), expenses: [])
      #expect(next.carryInCents == expectedCents)
      #expect(next.remainingPeriodCents == expectedCents + 100_000 - (newAmountCents ?? 0))
    }
  }

  @Test("Bill status changes on later days preserve earlier allowances after reloading")
  func billMarkHistory() throws {
    let context = ModelContext(container)
    let budget = try makeBudget(in: context, withRent: true)
    let rent = try #require(budget.fixedBills.first)
    budget.setStatus(.skipped, of: rent, now: today, calendar: calendar)
    let thursday = calendar.date(2026, 6, 4, 12)
    budget.setStatus(.paid(cents: 25_000), of: rent, now: thursday, calendar: calendar)
    let friday = calendar.date(2026, 6, 5, 12)
    budget.setStatus(.unpaid, of: rent, now: friday, calendar: calendar)
    try context.save()

    let loaded = ModelContext(container)
    let saved = try #require(try loaded.fetch(FetchDescriptor<Budget>()).first)
    let bill = try #require(saved.fixedBills.first)
    let period = engine.period(containing: friday, of: BudgetSnapshot(saved))
    #expect(saved.status(of: bill, in: period) == .unpaid)
    #expect(saved.billPayments.count == 3)
    #expect(saved.billPayments.reduce(0) { $0 + $1.adjustmentCents } == 0)
    let history = HistoryEngine(calendar: calendar).periods(
      budget: BudgetSnapshot(saved), expenses: [HistoryExpense<String>](), now: friday
    )[0]
    #expect(history.days.reversed().map(\.allowanceCents) == [
      10_000, 11_666, 20_000, 18_750, 23_333,
    ])
    #expect(history.remainingCents == 70_000)
  }
}
