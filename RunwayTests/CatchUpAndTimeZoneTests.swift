import Foundation
import SwiftData
import Testing

@testable import Runway

/// Opening the app after days or periods away, and moving between time zones. Weekly $700
/// budgets anchored Monday 2026-06-01.
struct CatchUpAndTimeZoneTests {
  let chicago = Calendar.gregorian("America/Chicago")
  let losAngeles = Calendar.gregorian("America/Los_Angeles")
  let tokyo = Calendar.gregorian("Asia/Tokyo")
  let container: ModelContainer

  init() throws {
    container = try RunwayModelContainer.make(inMemory: true)
  }

  func weekly(_ calendar: Calendar) -> BudgetSnapshot {
    BudgetSnapshot(
      periodLength: .weekly,
      periodStart: calendar.date(2026, 6, 1),
      spendablePerPeriodCents: 70_000
    )
  }

  func makeBudget(in context: ModelContext) throws -> Budget {
    let budget = Budget(
      periodLength: .weekly,
      periodStart: chicago.date(2026, 6, 1),
      spendablePerPeriodCents: 70_000,
      timeZoneIdentifier: "America/Chicago"
    )
    context.insert(budget)
    try context.save()
    return budget
  }

  // MARK: - Catching up

  @Test("Opening after days away catches up the allowance and carryover across boundaries")
  func catchUpAcrossBoundaries() {
    let engine = AllowanceEngine(calendar: chicago)
    let budget = weekly(chicago)
    let monday = [expense(10_000, chicago.date(2026, 6, 1, 12))]
    // Not opened since Monday; Friday: (700 - 100) / 3.
    let friday = engine.currentAllowance(
      budget: budget,
      expenses: monday,
      now: chicago.date(2026, 6, 5, 9)
    )
    #expect(friday.allowanceTodayCents == 20_000)

    // Two boundaries later: Jun 1–7 leaves 200, Jun 8–14 leaves 700 + 200 - 1,000 = -100.
    let expenses = [
      expense(50_000, chicago.date(2026, 6, 3, 12)),
      expense(100_000, chicago.date(2026, 6, 10, 12)),
    ]
    let result = engine.currentAllowance(
      budget: budget,
      expenses: expenses,
      now: chicago.date(2026, 6, 17, 9)
    )
    #expect(result.period.index == 2)
    #expect(result.carryInCents == -10_000)
    // (700 - 100) / 5 days (Jun 17–21).
    #expect(result.allowanceTodayCents == 12_000)
  }

  @Test("A carryover change that took effect while the app was closed applies on open")
  func carryoverChangeWhileAway() throws {
    let context = ModelContext(container)
    let budget = try makeBudget(in: context)
    budget.setCarryover(false, now: chicago.date(2026, 6, 3, 12), calendar: chicago)
    try context.save()

    let result = AllowanceEngine(calendar: chicago).currentAllowance(
      budget: BudgetSnapshot(budget),
      expenses: [expense(50_000, chicago.date(2026, 6, 3, 12))],
      now: chicago.date(2026, 6, 17, 9)
    )
    #expect(result.carryInCents == 0)
    #expect(result.allowanceTodayCents == 14_000)
  }

  @Test("Amount and schedule changes chain correctly through periods missed while away")
  func changesThenAway() throws {
    let context = ModelContext(container)
    let budget = try makeBudget(in: context)
    let expenses = [expense(10_000, chicago.date(2026, 6, 2, 12))]

    // Wednesday Jun 3: spendable up to $1,050 from today.
    var draft = BudgetDraft(budget: budget, locale: Money.fixedLocale)
    draft.spendableText = "1050"
    #expect(draft.apply(to: budget, now: chicago.date(2026, 6, 3, 12), calendar: chicago))
    // Wednesday Jun 10: biweekly from today.
    draft = BudgetDraft(budget: budget, locale: Money.fixedLocale)
    draft.periodLength = .biweekly
    draft.periodStart = chicago.date(2026, 6, 10)
    #expect(draft.apply(to: budget, now: chicago.date(2026, 6, 10, 12), calendar: chicago))
    try context.save()
    #expect(budget.amountChanges.count == 1)
    #expect(budget.scheduleChanges.count == 1)

    // Next opened Tuesday Jun 30.
    let now = chicago.date(2026, 6, 30, 9)
    let result = AllowanceEngine(calendar: chicago).currentAllowance(
      budget: BudgetSnapshot(budget),
      expenses: expenses,
      now: now
    )
    // Jun 1–7: 1,050 - 100 = 950. Jun 8–9: 1,050 × 2 / 7 = 300, so 1,250. Jun 10–23: 1,050,
    // so 2,300. Jun 24 – Jul 7: (1,050 + 2,300) / 8 days left.
    #expect(result.period.index == 3)
    #expect(result.period.start == chicago.date(2026, 6, 24))
    #expect(result.carryInCents == 230_000)
    #expect(result.allowanceTodayCents == 41_875)

    let periods = HistoryEngine(calendar: chicago).periods(
      budget: BudgetSnapshot(budget),
      expenses: expenses.map { historyExpense($0.amountCents, $0.date) },
      now: now
    )
    #expect(periods.map(\.carryOutCents) == [nil, 230_000, 125_000, 95_000])
    #expect(periods.map(\.carryInCents) == [230_000, 125_000, 95_000, 0])
  }

  // MARK: - Time zones

  @Test("The day boundary follows the calendar's time zone")
  func dayBoundaryFollowsTimeZone() {
    // 11:30 PM Thursday in Los Angeles is 1:30 AM Friday in Chicago.
    let lateThursday = losAngeles.date(2026, 6, 4, 23, 30)
    let expenses = [expense(5_000, lateThursday)]

    let inLosAngeles = AllowanceEngine(calendar: losAngeles).currentAllowance(
      budget: weekly(losAngeles),
      expenses: expenses,
      now: lateThursday
    )
    #expect(inLosAngeles.spentTodayCents == 5_000)
    #expect(inLosAngeles.daysLeft == 4)

    let inChicago = AllowanceEngine(calendar: chicago).currentAllowance(
      budget: weekly(chicago),
      expenses: expenses,
      now: lateThursday
    )
    #expect(inChicago.spentTodayCents == 5_000)
    #expect(inChicago.daysLeft == 3)
  }

  @Test("Moving time zones keeps paydays and change dates on the same calendar days")
  func adoptTimeZone() throws {
    let context = ModelContext(container)
    let budget = try makeBudget(in: context)
    let wednesday = chicago.date(2026, 6, 3, 12)
    budget.setCarryover(false, now: wednesday, calendar: chicago)
    budget.updatePeriod(.weekly, start: chicago.date(2026, 6, 5), now: wednesday, calendar: chicago)
    var draft = BudgetDraft(budget: budget, locale: Money.fixedLocale)
    draft.spendableText = "800"
    #expect(draft.apply(to: budget, now: wednesday, calendar: chicago))
    try context.save()

    // Without adopting, Los Angeles reads Chicago's midnight as 10 PM the day before.
    let stale = AllowanceEngine(calendar: losAngeles).period(at: 0, of: BudgetSnapshot(budget))
    #expect(stale.start == losAngeles.date(2026, 5, 31))

    #expect(budget.adoptTimeZone(of: losAngeles))
    try context.save()
    #expect(budget.timeZoneIdentifier == "America/Los_Angeles")
    #expect(budget.periodStart == losAngeles.date(2026, 6, 5))
    let change = try #require(budget.scheduleChanges.first)
    #expect(change.previousPeriodStart == losAngeles.date(2026, 6, 1))
    #expect(change.effectiveAt == losAngeles.date(2026, 6, 3))
    #expect(budget.carryoverChanges.map(\.effectiveAt) == [losAngeles.date(2026, 6, 5)])
    #expect(budget.amountChanges.map(\.effectiveAt) == [losAngeles.date(2026, 6, 3)])
    #expect(!budget.adoptTimeZone(of: losAngeles))

    let engine = AllowanceEngine(calendar: losAngeles)
    let periods = engine.periods(
      through: losAngeles.date(2026, 6, 5, 9),
      of: BudgetSnapshot(budget)
    )
    #expect(periods.map(\.start) == [1, 3, 5].map { losAngeles.date(2026, 6, $0) })

    let localAllowance = engine.currentAllowance(
      budget: BudgetSnapshot(budget),
      expenses: [],
      now: losAngeles.date(2026, 6, 5, 9)
    )
    #expect(localAllowance.daysLeft == 7)
    #expect(localAllowance.carryInCents == 0)
    #expect(localAllowance.allowanceTodayCents == 11_428)

    // Tokyo is ahead of Chicago; the days stay put there too.
    #expect(budget.adoptTimeZone(of: tokyo))
    #expect(budget.periodStart == tokyo.date(2026, 6, 5))
    #expect(budget.scheduleChanges.first?.effectiveAt == tokyo.date(2026, 6, 3))
  }

  @Test("A budget without a recorded time zone just records the current one")
  func adoptFirstTimeZone() throws {
    let budget = Budget(periodStart: chicago.date(2026, 6, 1), spendablePerPeriodCents: 70_000)
    #expect(budget.timeZoneIdentifier.isEmpty)
    #expect(budget.adoptTimeZone(of: chicago))
    #expect(budget.timeZoneIdentifier == "America/Chicago")
    #expect(budget.periodStart == chicago.date(2026, 6, 1))

    // A new budget from setup records the time zone it was set up in.
    var draft = BudgetDraft(periodStart: chicago.date(2026, 6, 1), locale: Money.fixedLocale)
    draft.spendableText = "700"
    let context = ModelContext(container)
    let saved = try #require(draft.insertBudget(into: context, calendar: chicago))
    #expect(saved.timeZoneIdentifier == "America/Chicago")
  }
}
