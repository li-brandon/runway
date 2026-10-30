import Foundation
import Testing

@testable import Runway

func historyExpense(
  _ amountCents: Int,
  _ date: Date,
  _ category: String = "other"
) -> HistoryExpense<String> {
  HistoryExpense(amountCents: amountCents, date: date, categoryID: category)
}

struct HistoryEngineTests {
  let calendar = Calendar.gregorian("America/Chicago")
  var engine: HistoryEngine { HistoryEngine(calendar: calendar) }

  /// Weekly, $700 available, starting Monday June 1, 2026.
  var weekly: BudgetSnapshot {
    BudgetSnapshot(
      periodLength: .weekly,
      periodStart: calendar.date(2026, 6, 1),
      spendablePerPeriodCents: 70_000
    )
  }

  /// Every day row matches `AllowanceEngine` evaluated at noon on that day.
  func expectMatchesAllowanceEngine(
    _ periods: [HistoryPeriod<String>],
    budget: BudgetSnapshot,
    expenses: [HistoryExpense<String>]
  ) {
    let allowanceEngine = AllowanceEngine(calendar: calendar)
    let snapshots = expenses.map { ExpenseSnapshot(amountCents: $0.amountCents, date: $0.date) }
    for period in periods {
      let carryIn = allowanceEngine.carryInCents(
        to: period.period,
        budget: budget,
        expenses: snapshots
      )
      #expect(period.carryInCents == carryIn)
      for day in period.days {
        let noon = calendar.date(byAdding: .hour, value: 12, to: day.date)!
        let result = allowanceEngine.allowance(
          in: period.period,
          budget: budget,
          expenses: snapshots,
          carryInCents: carryIn,
          now: noon
        )
        #expect(day.allowanceCents == result.allowanceTodayCents)
        #expect(day.spentCents == result.spentTodayCents)
      }
    }
  }

  @Test("Expenses before the start are in beforeBudget, in no period, and change no figures")
  func beforeBudgetExpenses() {
    let inBudget = [
      historyExpense(12_000, calendar.date(2026, 6, 1), "food"),
      historyExpense(5_000, calendar.date(2026, 6, 9, 18), "fun"),
    ]
    let earlier = [
      historyExpense(40_000, calendar.date(2026, 5, 20, 9), "rent"),
      // The last second before local midnight on the first day.
      historyExpense(-1_000, calendar.date(2026, 5, 31, 23, 59, 59), "food"),
      historyExpense(90_000, calendar.date(2026, 5, 25, 9), "fun"),
    ]
    let all = inBudget + earlier
    let now = calendar.date(2026, 6, 10, 12)

    let periods = engine.periods(budget: weekly, expenses: all, now: now)
    #expect(periods == engine.periods(budget: weekly, expenses: inBudget, now: now))
    #expect(periods.count == 2)
    #expect(periods.map(\.spentCents) == [5_000, 12_000])
    #expect(periods[1].carryOutCents == 58_000)
    #expect(periods[0].carryInCents == 58_000)
    #expect(!periods[1].categories.contains { $0.categoryID == "rent" })

    let before = engine.beforeBudget(all, budget: weekly) { $0.date }
    #expect(before == [earlier[1], earlier[2], earlier[0]])

    // Today's figures agree, so nothing counts them there either.
    let allowance = AllowanceEngine(calendar: calendar)
    let allSnapshots = all.map { expense($0.amountCents, $0.date) }
    let inBudgetSnapshots = inBudget.map { expense($0.amountCents, $0.date) }
    let result = allowance.currentAllowance(budget: weekly, expenses: allSnapshots, now: now)
    let baseline = allowance.currentAllowance(
      budget: weekly,
      expenses: inBudgetSnapshots,
      now: now
    )
    #expect(result == baseline)
  }

  @Test("Before the budget means before the first period, even after a schedule change")
  func beforeBudgetAfterScheduleChange() {
    // The Monday anchor stays the first period's start after moving to Friday paydays.
    let changed = weekly.changingSchedule(
      to: .weekly,
      start: calendar.date(2026, 6, 5),
      now: calendar.date(2026, 6, 3, 12),
      calendar: calendar
    )
    let expenses = [
      historyExpense(1_000, calendar.date(2026, 5, 31, 12)),
      historyExpense(2_000, calendar.date(2026, 6, 2, 12)),
    ]
    let before = engine.beforeBudget(expenses, budget: changed) { $0.date }
    #expect(before == [expenses[0]])
    #expect(engine.editablePeriod(of: expenses[0].date, budget: changed) == .beforeBudget)
    let own = engine.editablePeriod(of: expenses[1].date, budget: changed)
    #expect(own.start == calendar.date(2026, 6, 1))
    #expect(own.end == calendar.date(2026, 6, 3))
  }

  @Test("An expense before the budget edits to any date through now, keeping its own by default")
  func beforeBudgetEditDates() {
    let now = calendar.date(2026, 6, 10, 12)
    var draft = ExpenseDraft(now: calendar.date(2026, 5, 20, 9))
    #expect(draft.clampedDate(in: .beforeBudget, now: now) == draft.date)
    draft.date = calendar.date(2026, 6, 3, 9)
    #expect(draft.clampedDate(in: .beforeBudget, now: now) == draft.date)
    draft.date = calendar.date(2026, 6, 11, 9)
    #expect(draft.clampedDate(in: .beforeBudget, now: now) == now)
  }

  @Test("Day rows show allowance, spending, and over/under through today, newest first")
  func dayRows() {
    let expenses = [
      historyExpense(12_000, calendar.date(2026, 6, 1, 9), "food"),
      historyExpense(5_000, calendar.date(2026, 6, 2, 18), "fun"),
      historyExpense(-1_000, calendar.date(2026, 6, 3, 10), "food"),
      historyExpense(3_000, calendar.date(2026, 6, 4, 8), "food"),
      historyExpense(50_000, calendar.date(2026, 6, 5, 9), "rent"),
    ]
    let now = calendar.date(2026, 6, 4, 12)
    let periods = engine.periods(budget: weekly, expenses: expenses, now: now)
    #expect(periods.count == 1)
    let period = periods[0]
    #expect(period.isCurrent)
    #expect(
      period.days.map(\.date) == [4, 3, 2, 1].map { calendar.date(2026, 6, $0) }
    )
    #expect(period.days.map(\.allowanceCents) == [13_500, 10_600, 9_666, 10_000])
    #expect(period.days.map(\.spentCents) == [3_000, -1_000, 5_000, 12_000])
    #expect(period.days.map(\.remainingCents) == [10_500, 11_600, 4_666, -2_000])
    #expect(period.days.map(\.isOver) == [false, false, false, true])
    #expect(period.days.map(\.isToday) == [true, false, false, false])
    expectMatchesAllowanceEngine(periods, budget: weekly, expenses: expenses)

    // The future expense waits for its day, as on Today.
    #expect(period.spentCents == 19_000)
    #expect(period.availableCents == 70_000)
    #expect(period.remainingCents == 51_000)
    #expect(period.daysOver == 1)
    #expect(period.carryOutCents == nil)
  }

  @Test("Period totals, days over, and carry in/out chain with carryover on")
  func carryoverOn() {
    let expenses = [
      historyExpense(60_000, calendar.date(2026, 6, 2, 12)),
      historyExpense(85_000, calendar.date(2026, 6, 10, 12)),
      historyExpense(1_000, calendar.date(2026, 6, 15, 9)),
    ]
    let now = calendar.date(2026, 6, 16, 12)
    let periods = engine.periods(budget: weekly, expenses: expenses, now: now)
    #expect(periods.map(\.period.index) == [2, 1, 0])
    #expect(periods.map(\.isCurrent) == [true, false, false])
    #expect(periods.map(\.carryInCents) == [-5_000, 10_000, 0])
    #expect(periods.map(\.carryOutCents) == [nil, -5_000, 10_000])
    #expect(periods.map(\.spentCents) == [1_000, 85_000, 60_000])
    #expect(periods.map(\.availableCents) == [65_000, 80_000, 70_000])
    #expect(periods.map(\.days.count) == [2, 7, 7])
    #expect(periods.allSatisfy { $0.carryoverEnabledAtStart })
    // June 10 overspends; the negative allowances after it are over too, as on Today.
    #expect(periods[1].daysOver == 5)
    #expect(periods[2].daysOver == 1)
    expectMatchesAllowanceEngine(periods, budget: weekly, expenses: expenses)
  }

  @Test("Carryover off starts every period fresh; a change applies from its boundary")
  func carryoverOffAndChanged() {
    let expenses = [
      historyExpense(60_000, calendar.date(2026, 6, 2, 12)),
      historyExpense(85_000, calendar.date(2026, 6, 10, 12)),
    ]
    let now = calendar.date(2026, 6, 16, 12)

    var off = weekly
    off.carryoverEnabled = false
    let fresh = engine.periods(budget: off, expenses: expenses, now: now)
    #expect(fresh.map(\.carryInCents) == [0, 0, 0])
    #expect(fresh.map(\.carryOutCents) == [nil, 0, 0])
    #expect(fresh.map(\.remainingCents) == [70_000, -15_000, 10_000])
    #expect(fresh.map(\.carryoverEnabledAtStart) == [false, false, false])
    expectMatchesAllowanceEngine(fresh, budget: off, expenses: expenses)

    var changed = weekly
    changed.carryoverEnabled = false
    changed.carryoverChanges = [
      CarryoverChangeSnapshot(
        enabled: false,
        previousEnabled: true,
        effectiveAt: calendar.date(2026, 6, 15)
      )
    ]
    let periods = engine.periods(budget: changed, expenses: expenses, now: now)
    #expect(periods.map(\.carryInCents) == [0, 10_000, 0])
    #expect(periods.map(\.carryOutCents) == [nil, 0, 10_000])
    #expect(periods.map(\.carryoverEnabledAtStart) == [false, true, true])
    expectMatchesAllowanceEngine(periods, budget: changed, expenses: expenses)
  }

  @Test("Category totals are net of refunds, sorted by amount, ties in first-spending order")
  func categoryTotals() {
    let expenses = [
      historyExpense(1_000, calendar.date(2026, 6, 2, 9), "a"),
      historyExpense(1_000, calendar.date(2026, 6, 1, 9), "b"),
      historyExpense(4_000, calendar.date(2026, 6, 1, 10), "food"),
      historyExpense(-1_500, calendar.date(2026, 6, 2, 10), "food"),
      historyExpense(-700, calendar.date(2026, 6, 3, 10), "returns"),
      historyExpense(9_000, calendar.date(2026, 6, 5, 10), "later"),
      historyExpense(8_000, calendar.date(2026, 5, 31, 10), "before start"),
    ]
    let now = calendar.date(2026, 6, 3, 12)
    let period = engine.periods(budget: weekly, expenses: expenses, now: now)[0]
    #expect(
      period.categories == [
        HistoryCategoryTotal(categoryID: "food", spentCents: 2_500),
        HistoryCategoryTotal(categoryID: "b", spentCents: 1_000),
        HistoryCategoryTotal(categoryID: "a", spentCents: 1_000),
        HistoryCategoryTotal(categoryID: "returns", spentCents: -700),
      ]
    )
    #expect(period.categories.reduce(0) { $0 + $1.spentCents } == period.spentCents)
  }

  @Test("Moving an expense to an earlier day changes the allowances of the days after it")
  func moveEarlier() {
    let now = calendar.date(2026, 6, 4, 12)
    let original = [historyExpense(7_000, calendar.date(2026, 6, 3, 12))]
    let before = engine.periods(budget: weekly, expenses: original, now: now)[0]
    #expect(before.days.map(\.allowanceCents) == [15_750, 14_000, 11_666, 10_000])

    let moved = [historyExpense(7_000, calendar.date(2026, 6, 1, 12))]
    let after = engine.periods(budget: weekly, expenses: moved, now: now)[0]
    #expect(after.days.map(\.allowanceCents) == [15_750, 12_600, 10_500, 10_000])
    #expect(after.days.map(\.spentCents) == [0, 0, 0, 7_000])
    #expect(after.days.last?.isOver == false)
    expectMatchesAllowanceEngine([after], budget: weekly, expenses: moved)
  }

  @Test("Previous periods are browsable newest first back to the budget's start")
  func previousPeriods() {
    let budget = BudgetSnapshot(
      periodLength: .monthly,
      periodStart: calendar.date(2026, 1, 31),
      spendablePerPeriodCents: 100_000
    )
    let now = calendar.date(2026, 4, 2, 12)
    let periods = engine.periods(budget: budget, expenses: [HistoryExpense<String>](), now: now)
    #expect(periods.map(\.period.index) == [2, 1, 0])
    #expect(
      periods.map(\.period.start) == [
        calendar.date(2026, 3, 31),
        calendar.date(2026, 2, 28),
        calendar.date(2026, 1, 31),
      ]
    )
    #expect(periods.map(\.days.count) == [3, 31, 28])
    for (newer, older) in zip(periods, periods.dropFirst()) {
      #expect(older.period.end == newer.period.start)
    }
    #expect(engine.lastDay(of: periods[2].period) == calendar.date(2026, 2, 27))
    #expect(periods.map(\.carryInCents) == [200_000, 100_000, 0])
  }

  @Test("A budget that starts in the future has one current period with no days yet")
  func futureStart() {
    let now = calendar.date(2026, 5, 30, 12)
    let expenses = [historyExpense(1_000, calendar.date(2026, 5, 30, 9))]
    let periods = engine.periods(budget: weekly, expenses: expenses, now: now)
    #expect(periods.count == 1)
    #expect(periods[0].isCurrent)
    #expect(periods[0].days.isEmpty)
    #expect(periods[0].spentCents == 0)
    #expect(periods[0].categories.isEmpty)
  }

  @Test("Day rows follow calendar days across 23- and 25-hour DST days")
  func daylightSaving() {
    for (start, now) in [
      (calendar.date(2026, 3, 1), calendar.date(2026, 3, 14, 12)),
      (calendar.date(2026, 10, 25), calendar.date(2026, 11, 7, 12)),
    ] {
      let budget = BudgetSnapshot(
        periodLength: .biweekly,
        periodStart: start,
        spendablePerPeriodCents: 140_000
      )
      // 20 elapsed hours after midnight is still the same day on 23- and 25-hour days.
      let expenses = (0..<14).map { offset in
        let day = calendar.date(byAdding: .day, value: offset, to: start)!
        let evening = calendar.date(byAdding: .hour, value: 20, to: day)!
        return historyExpense(1_000 + offset * 100, evening)
      }
      let periods = engine.periods(budget: budget, expenses: expenses, now: now)
      #expect(periods.count == 1)
      let days = periods[0].days
      #expect(days.count == 14)
      #expect(Set(days.map(\.date)).count == 14)
      #expect(days.allSatisfy { calendar.startOfDay(for: $0.date) == $0.date })
      #expect(days.map(\.spentCents) == (0..<14).reversed().map { 1_000 + $0 * 100 })
      expectMatchesAllowanceEngine(periods, budget: budget, expenses: expenses)
    }
  }

  @Test("Expenses group by day within a period, keeping their order")
  func itemsByDay() {
    let period = BudgetPeriod(
      index: 0,
      start: calendar.date(2026, 6, 1),
      end: calendar.date(2026, 6, 8)
    )
    let items = [
      (name: "late", date: calendar.date(2026, 6, 2, 20)),
      (name: "early", date: calendar.date(2026, 6, 2, 8)),
      (name: "first", date: calendar.date(2026, 6, 1)),
      (name: "outside", date: calendar.date(2026, 6, 8)),
    ]
    let byDay = engine.itemsByDay(items, in: period) { $0.date }
    #expect(byDay.count == 2)
    #expect(byDay[calendar.date(2026, 6, 2)]?.map(\.name) == ["late", "early"])
    #expect(byDay[calendar.date(2026, 6, 1)]?.map(\.name) == ["first"])
  }

  @Test("Hundreds of expenses over months compute quickly and match the allowance engine")
  func manyExpenses() {
    let budget = BudgetSnapshot(
      periodLength: .weekly,
      periodStart: calendar.date(2026, 1, 5),
      spendablePerPeriodCents: 70_000
    )
    let start = calendar.date(2026, 1, 5)
    let expenses = (0..<500).map { index in
      let day = calendar.date(byAdding: .day, value: index * 7 / 20, to: start)!
      let date = calendar.date(byAdding: .minute, value: 480 + index % 20 * 30, to: day)!
      return historyExpense(500 + index % 37 * 150, date, "c\(index % 6)")
    }
    let now = calendar.date(2026, 6, 30, 12)
    var periods: [HistoryPeriod<String>] = []
    let elapsed = ContinuousClock().measure {
      periods = engine.periods(budget: budget, expenses: expenses.shuffled(), now: now)
    }
    #expect(elapsed < .seconds(1))
    #expect(periods.count == 26)
    let total = periods.reduce(0) { $0 + $1.spentCents }
    #expect(total == expenses.reduce(0) { $0 + $1.amountCents })

    let current = AllowanceEngine(calendar: calendar).currentAllowance(
      budget: budget,
      expenses: expenses.map { ExpenseSnapshot(amountCents: $0.amountCents, date: $0.date) },
      now: now
    )
    #expect(periods[0].carryInCents == current.carryInCents)
    #expect(periods[0].days.first?.allowanceCents == current.allowanceTodayCents)
    #expect(periods[0].days.first?.spentCents == current.spentTodayCents)
  }
}
