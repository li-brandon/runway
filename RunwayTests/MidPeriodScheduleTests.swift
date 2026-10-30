import Foundation
import SwiftData
import Testing

@testable import Runway

/// Period length and payday changes mid-period, and when carryover changes apply. Weekly $700
/// budget anchored Monday 2026-06-01 in Chicago, with $100 spent that Monday.
struct MidPeriodScheduleTests {
  let calendar = Calendar.gregorian("America/Chicago")
  let container: ModelContainer

  init() throws {
    container = try RunwayModelContainer.make(inMemory: true)
  }

  var engine: AllowanceEngine { AllowanceEngine(calendar: calendar) }

  var mondayLunch: [ExpenseSnapshot] { [expense(10_000, calendar.date(2026, 6, 1, 12))] }

  func makeBudget(in context: ModelContext, carryover: Bool = true) throws -> Budget {
    let budget = Budget(
      periodLength: .weekly,
      periodStart: calendar.date(2026, 6, 1),
      spendablePerPeriodCents: 70_000,
      carryoverEnabled: carryover
    )
    context.insert(budget)
    try context.save()
    return budget
  }

  func allowance(_ budget: Budget, now: Date, expenses: [ExpenseSnapshot]) -> AllowanceResult {
    engine.currentAllowance(budget: BudgetSnapshot(budget), expenses: expenses, now: now)
  }

  // MARK: - Schedule changes

  @Test("Moving the payday mid-period ends the period today, with money for the days it ran")
  func movePayday() throws {
    let context = ModelContext(container)
    let budget = try makeBudget(in: context)
    let now = calendar.date(2026, 6, 3, 12)
    var draft = BudgetDraft(budget: budget, locale: Money.fixedLocale)
    // Friday paydays.
    draft.periodStart = calendar.date(2026, 6, 5)
    #expect(draft.changesSchedule(of: budget, calendar: calendar))

    let preview = try #require(
      draft.schedulePreview(for: budget, expenses: mondayLunch, now: now, calendar: calendar)
    )
    #expect(preview.endingPeriod.start == calendar.date(2026, 6, 1))
    #expect(preview.endingPeriod.end == calendar.date(2026, 6, 3))
    #expect(preview.endingPeriod.isPartial)
    // 2 of 7 days: 700 × 2 / 7 = 200, minus Monday's 100.
    #expect(preview.leftoverCents == 10_000)
    #expect(preview.carriesOver)
    #expect(preview.newPeriod.start == calendar.date(2026, 6, 3))
    #expect(preview.newPeriod.end == calendar.date(2026, 6, 5))

    #expect(draft.apply(to: budget, now: now, calendar: calendar))
    try context.save()
    let changes = try context.fetch(FetchDescriptor<ScheduleChange>())
    #expect(changes.count == 1)
    #expect(changes.first?.previousPeriodLength == .weekly)
    #expect(changes.first?.previousPeriodStart == calendar.date(2026, 6, 1))
    #expect(changes.first?.effectiveAt == calendar.date(2026, 6, 3))
    #expect(budget.periodStart == calendar.date(2026, 6, 5))

    // Wed–Thu is 2 days of the May 29 – Jun 4 week: 200, plus 100 carried in, over 2 days.
    let result = allowance(budget, now: now, expenses: mondayLunch)
    #expect(result.period.index == 1)
    #expect(result.carryInCents == 10_000)
    #expect(result.daysLeft == 2)
    #expect(result.allowanceTodayCents == 15_000)
    #expect(result.remainingPeriodCents == 30_000)

    // Then whole Friday-to-Thursday weeks, with Wed–Thu's 300 carried in.
    let friday = allowance(budget, now: calendar.date(2026, 6, 5, 9), expenses: mondayLunch)
    #expect(friday.period.start == calendar.date(2026, 6, 5))
    #expect(friday.period.end == calendar.date(2026, 6, 12))
    #expect(!friday.period.isPartial)
    #expect(friday.carryInCents == 30_000)

    // History keeps Monday and Tuesday's allowances and shows the period's prorated money.
    let periods = HistoryEngine(calendar: calendar).periods(
      budget: BudgetSnapshot(budget),
      expenses: mondayLunch.map { historyExpense($0.amountCents, $0.date) },
      now: now
    )
    #expect(periods.count == 2)
    let ended = periods[1]
    #expect(ended.days.map(\.allowanceCents) == [10_000, 10_000])
    #expect(ended.spendableCents == 20_000)
    #expect(ended.carryOutCents == 10_000)
    #expect(periods[0].spendableCents == 20_000)
    #expect(periods[0].carryInCents == 10_000)
  }

  @Test("Switching to monthly with carryover off drops the leftover, as the dialog says")
  func switchToMonthlyWithCarryoverOff() throws {
    let context = ModelContext(container)
    let budget = try makeBudget(in: context, carryover: false)
    let now = calendar.date(2026, 6, 10, 12)
    var draft = BudgetDraft(budget: budget, locale: Money.fixedLocale)
    draft.periodLength = .monthly

    let preview = try #require(
      draft.schedulePreview(for: budget, expenses: [], now: now, calendar: calendar)
    )
    #expect(preview.endingPeriod.start == calendar.date(2026, 6, 8))
    #expect(preview.endingPeriod.end == calendar.date(2026, 6, 10))
    // 700 × 2 / 7.
    #expect(preview.leftoverCents == 20_000)
    #expect(!preview.carriesOver)
    #expect(preview.newPeriod.end == calendar.date(2026, 7, 1))

    #expect(draft.apply(to: budget, now: now, calendar: calendar))
    try context.save()

    // Jun 10–30 is 21 of June's 30 days: 700 × 21 / 30 = 490, over 21 days.
    let result = allowance(budget, now: now, expenses: [])
    #expect(result.carryInCents == 0)
    #expect(result.daysLeft == 21)
    #expect(result.allowanceTodayCents == 2_333)
    #expect(result.remainingPeriodCents == 49_000)
    // July is a whole month: 700 / 31.
    let july = allowance(budget, now: calendar.date(2026, 7, 1, 9), expenses: [])
    #expect(july.period.start == calendar.date(2026, 7, 1))
    #expect(july.allowanceTodayCents == 2_258)
  }

  @Test("Changing the period on what is payday under both schedules ends nothing early")
  func changeOnPayday() throws {
    let context = ModelContext(container)
    let budget = try makeBudget(in: context)
    let now = calendar.date(2026, 6, 8, 9)
    var draft = BudgetDraft(budget: budget, locale: Money.fixedLocale)
    draft.periodLength = .biweekly
    draft.periodStart = calendar.date(2026, 6, 8)

    let preview = try #require(
      draft.schedulePreview(for: budget, expenses: mondayLunch, now: now, calendar: calendar)
    )
    #expect(!preview.endingPeriod.isPartial)
    #expect(preview.endingPeriod.end == calendar.date(2026, 6, 8))
    #expect(preview.leftoverCents == 60_000)
    #expect(preview.newPeriod.end == calendar.date(2026, 6, 22))

    #expect(draft.apply(to: budget, now: now, calendar: calendar))
    let result = allowance(budget, now: now, expenses: mondayLunch)
    // (700 + 600) / 14.
    #expect(result.carryInCents == 60_000)
    #expect(result.allowanceTodayCents == 9_285)
  }

  @Test("A second schedule change the same day replaces the first, and changing back removes it")
  func sameDayScheduleEdits() throws {
    let context = ModelContext(container)
    let budget = try makeBudget(in: context)
    let now = calendar.date(2026, 6, 3, 12)
    let friday = calendar.date(2026, 6, 5)

    budget.updatePeriod(.weekly, start: friday, now: now, calendar: calendar)
    let afternoon = calendar.date(2026, 6, 3, 15)
    budget.updatePeriod(.monthly, start: friday, now: afternoon, calendar: calendar)
    #expect(budget.scheduleChanges.count == 1)
    #expect(budget.scheduleChanges.first?.previousPeriodLength == .weekly)
    #expect(budget.scheduleChanges.first?.previousPeriodStart == calendar.date(2026, 6, 1))

    let monday = calendar.date(2026, 6, 1)
    let evening = calendar.date(2026, 6, 3, 18)
    budget.updatePeriod(.weekly, start: monday, now: evening, calendar: calendar)
    try context.save()

    #expect(budget.scheduleChanges.isEmpty)
    #expect(try context.fetchCount(FetchDescriptor<ScheduleChange>()) == 0)
    let result = allowance(budget, now: now, expenses: mondayLunch)
    #expect(result.period == BudgetPeriod(index: 0, start: monday, end: calendar.date(2026, 6, 8)))
    #expect(result.allowanceTodayCents == 12_000)
  }

  @Test("No dialog is needed before the first period starts or when the schedule is unchanged")
  func noPreview() throws {
    let context = ModelContext(container)
    let budget = try makeBudget(in: context)
    var draft = BudgetDraft(budget: budget, locale: Money.fixedLocale)
    let now = calendar.date(2026, 6, 3, 12)
    #expect(!draft.changesSchedule(of: budget, calendar: calendar))
    #expect(draft.schedulePreview(for: budget, expenses: [], now: now, calendar: calendar) == nil)

    draft.periodLength = .monthly
    let beforeStart = calendar.date(2026, 5, 30, 12)
    let preview = draft.schedulePreview(
      for: budget,
      expenses: [],
      now: beforeStart,
      calendar: calendar
    )
    #expect(preview == nil)
  }

  // MARK: - Carryover

  @Test("Toggling carryover mid-period says it takes effect at the next boundary")
  func carryoverTakesEffectNextPeriod() throws {
    let context = ModelContext(container)
    let budget = try makeBudget(in: context)
    let now = calendar.date(2026, 6, 3, 12)
    var draft = BudgetDraft(budget: budget, locale: Money.fixedLocale)
    #expect(draft.carryoverChangeDate(for: budget, now: now, calendar: calendar) == nil)

    draft.carryoverEnabled = false
    #expect(
      draft.carryoverChangeDate(for: budget, now: now, calendar: calendar)
        == calendar.date(2026, 6, 8)
    )
    // With a payday change in the same edit, the next boundary is the new schedule's.
    draft.periodStart = calendar.date(2026, 6, 5)
    #expect(
      draft.carryoverChangeDate(for: budget, now: now, calendar: calendar)
        == calendar.date(2026, 6, 5)
    )
    draft.periodStart = calendar.date(2026, 6, 1)
    #expect(draft.apply(to: budget, now: now, calendar: calendar))
    try context.save()

    let pending = try #require(
      engine.pendingCarryoverChange(budget: BudgetSnapshot(budget), now: now)
    )
    #expect(!pending.enabled)
    #expect(pending.effectiveAt == calendar.date(2026, 6, 8))
    // This period keeps its carryover; reopening setup still shows the pending change.
    var reopened = BudgetDraft(budget: budget, locale: Money.fixedLocale)
    #expect(
      reopened.carryoverChangeDate(for: budget, now: now, calendar: calendar)
        == calendar.date(2026, 6, 8)
    )
    reopened.carryoverEnabled = true
    #expect(reopened.carryoverChangeDate(for: budget, now: now, calendar: calendar) == nil)

    // Once the boundary passes, nothing is pending.
    let nextMonday = calendar.date(2026, 6, 8, 9)
    #expect(engine.pendingCarryoverChange(budget: BudgetSnapshot(budget), now: nextMonday) == nil)
  }
}
