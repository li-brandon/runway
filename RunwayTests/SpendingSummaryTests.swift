import Foundation
import SwiftData
import SwiftUI
import Testing

@testable import Runway

struct SpendingSummaryTests {
  let calendar = Calendar.gregorian("America/Chicago")

  @Test("Day is local midnight to midnight, including DST")
  func dayBounds() {
    let engine = SpendingSummaryEngine(calendar: calendar)
    let windows = engine.windows(
      view: .day,
      mode: .rolling,
      now: calendar.date(2026, 3, 8, 12)
    )
    #expect(windows.current.start == calendar.date(2026, 3, 8))
    #expect(windows.current.end == calendar.date(2026, 3, 9))
    #expect(windows.previous.start == calendar.date(2026, 3, 7))
    #expect(windows.previous.end == windows.current.start)
    #expect(windows.current.end.timeIntervalSince(windows.current.start) == 23 * 3_600)
  }

  @Test("Calendar weeks honor firstWeekday and compare equal elapsed days")
  func calendarWeeks() {
    for (firstWeekday, startDay, previousDay) in [(1, 7, 31), (2, 8, 1)] {
      var custom = calendar
      custom.firstWeekday = firstWeekday
      let windows = SpendingSummaryEngine(calendar: custom).windows(
        view: .week,
        mode: .calendar,
        now: custom.date(2026, 6, 10, 12)
      )
      #expect(windows.current.start == custom.date(2026, 6, startDay))
      #expect(windows.current.end == custom.date(2026, 6, 11))
      let previousMonth = firstWeekday == 1 ? 5 : 6
      #expect(windows.previous.start == custom.date(2026, previousMonth, previousDay))
      let currentDays = custom.dateComponents(
        [.day],
        from: windows.current.start,
        to: windows.current.end
      ).day
      let previousDays = custom.dateComponents(
        [.day],
        from: windows.previous.start,
        to: windows.previous.end
      ).day
      #expect(currentDays == previousDays)
    }
  }

  @Test("Calendar months cap the comparison at the shorter month's end")
  func calendarMonths() {
    for (year, februaryDays) in [(2024, 29), (2026, 28)] {
      let engine = SpendingSummaryEngine(calendar: calendar)
      let windows = engine.windows(
        view: .month,
        mode: .calendar,
        now: calendar.date(year, 3, 31, 12)
      )
      #expect(windows.current.start == calendar.date(year, 3, 1))
      #expect(windows.current.end == calendar.date(year, 4, 1))
      #expect(windows.previous.start == calendar.date(year, 2, 1))
      #expect(windows.previous.end == calendar.date(year, 3, 1))
      let days = calendar.dateComponents(
        [.day],
        from: windows.previous.start,
        to: windows.previous.end
      ).day
      #expect(days == februaryDays)
    }
    let partial = SpendingSummaryEngine(calendar: calendar).windows(
      view: .month,
      mode: .calendar,
      now: calendar.date(2026, 6, 10, 12)
    )
    #expect(partial.previous.start == calendar.date(2026, 5, 1))
    #expect(partial.previous.end == calendar.date(2026, 5, 11))
  }

  @Test("Rolling week and month have 7 and 30 local days, with adjacent previous windows")
  func rollingBounds() {
    for zone in ["UTC", "America/Chicago", "Asia/Tokyo"] {
      let fixed = Calendar.gregorian(zone)
      for (view, count) in [(SpendingView.week, 7), (.month, 30)] {
        let windows = SpendingSummaryEngine(calendar: fixed).windows(
          view: view,
          mode: .rolling,
          now: fixed.date(2026, 3, 10, 12)
        )
        let end = fixed.date(2026, 3, 11)
        let start = fixed.date(byAdding: .day, value: -count, to: end)!
        #expect(windows.current.start == start)
        #expect(windows.current.end == end)
        #expect(windows.previous.end == start)
        #expect(
          windows.previous.start == fixed.date(byAdding: .day, value: -count, to: start)
        )
      }
    }
  }

  @Test("Totals ignore boundaries, future spending and pre-budget spending; refunds reduce net")
  func totalsAndTrends() {
    let engine = SpendingSummaryEngine(calendar: calendar)
    let now = calendar.date(2026, 6, 10, 12)
    let budget = BudgetSnapshot(
      periodLength: .weekly,
      periodStart: calendar.date(2026, 5, 1),
      spendablePerPeriodCents: 70_000
    )
    for (current, previous, expected) in [
      (150, 100, 50.0), (50, 100, -50.0), (100, 100, 0.0),
      (-50, -100, 50.0), (-150, -100, -50.0), (-50, 100, -150.0),
    ] {
      let expenses = [
        HistoryExpense(amountCents: current + 25, date: now, categoryID: "food"),
        HistoryExpense(amountCents: -25, date: now, categoryID: "food"),
        HistoryExpense(
          amountCents: previous,
          date: calendar.date(2026, 6, 9),
          categoryID: "food"
        ),
        HistoryExpense(
          amountCents: 999,
          date: calendar.date(2026, 6, 11),
          categoryID: "food"
        ),
        HistoryExpense(
          amountCents: 999,
          date: calendar.date(2026, 4, 30),
          categoryID: "food"
        ),
      ]
      let result = engine.summary(
        budget: budget,
        expenses: expenses,
        view: .day,
        mode: .calendar,
        now: now
      )
      #expect(result.spentCents == current)
      #expect(result.previousSpentCents == previous)
      #expect(result.percentageChange == expected)
    }
    for current in [0, 100, -100] {
      let result = engine.summary(
        budget: budget,
        expenses: [HistoryExpense(amountCents: current, date: now, categoryID: 0)],
        view: .day,
        mode: .calendar,
        now: now
      )
      #expect(result.percentageChange == nil)
    }
  }

  @Test("Each view totals exactly its current and previous windows")
  func periodTotals() {
    let engine = SpendingSummaryEngine(calendar: calendar)
    let now = calendar.date(2026, 6, 10, 12)
    let budget = BudgetSnapshot(
      periodLength: .monthly,
      periodStart: calendar.date(2026, 1, 1),
      spendablePerPeriodCents: 100_000
    )
    for view in SpendingView.allCases {
      for mode in SpendingWindowMode.allCases {
        let windows = engine.windows(view: view, mode: mode, now: now)
        let expenses = [
          HistoryExpense(amountCents: 300, date: windows.current.start, categoryID: 0),
          HistoryExpense(amountCents: -50, date: now, categoryID: 0),
          HistoryExpense(amountCents: 100, date: windows.previous.start, categoryID: 0),
          HistoryExpense(amountCents: 999, date: windows.current.end, categoryID: 0),
        ]
        let result = engine.summary(
          budget: budget,
          expenses: expenses,
          view: view,
          mode: mode,
          now: now
        )
        #expect(result.spentCents == 250)
        #expect(result.previousSpentCents == 100)
        #expect(result.percentageChange == 150)
      }
    }
  }

  @Test("Budget slice sums base daily shares, preserving mid-period changes")
  func budgetSlice() {
    let start = calendar.date(2026, 6, 1)
    let now = calendar.date(2026, 6, 7, 12)
    let budget = BudgetSnapshot(
      periodLength: .weekly,
      periodStart: start,
      spendablePerPeriodCents: 14_000,
      carryoverEnabled: false,
      amountChanges: [
        AmountChangeSnapshot(previousCents: 7_000, effectiveAt: calendar.date(2026, 6, 4))
      ]
    )
    // Three days at 1,000 cents, then four days at 2,000 cents.
    let result = SpendingSummaryEngine(calendar: calendar).summary(
      budget: budget,
      expenses: [HistoryExpense<Int>](),
      view: .week,
      mode: .rolling,
      now: now
    )
    #expect(result.budgetCents == 11_000)
    #expect(result.spentCents == 0)
    #expect(result.previousSpentCents == 0)
    let expenses = [HistoryExpense(amountCents: 500, date: start, categoryID: 0)]
    for view in SpendingView.allCases {
      let summary = SpendingSummaryEngine(calendar: calendar).summary(
        budget: budget,
        expenses: expenses,
        view: view,
        mode: .rolling,
        now: now
      )
      let history = HistoryEngine(calendar: calendar).periods(
        budget: budget,
        expenses: expenses,
        now: now
      ).flatMap(\.days).filter { summary.window.contains($0.date) }
      #expect(summary.budgetCents == (view == .day ? 2_000 : 11_000))
      #expect(summary.spentCents == history.reduce(0) { $0 + $1.spentCents })
    }
  }

  @Test("An unspent period does not inflate the base budget slice with rollover")
  func unspentBudgetSlice() {
    let budget = BudgetSnapshot(
      periodLength: .biweekly,
      periodStart: calendar.date(2026, 6, 1),
      spendablePerPeriodCents: 112_000
    )
    let engine = SpendingSummaryEngine(calendar: calendar)
    for day in [7, 14, 21, 28] {
      let result = engine.summary(
        budget: budget,
        expenses: [HistoryExpense<Int>](),
        view: .week,
        mode: .rolling,
        now: calendar.date(2026, 6, day, 12)
      )
      #expect(result.budgetCents == 7 * 112_000 / 14)
    }
  }

  @Test("Base shares include dated extra money and bill adjustments from their day")
  func datedExtraBudgetSlice() {
    let start = calendar.date(2026, 6, 4)
    let budget = BudgetSnapshot(
      periodLength: .weekly,
      periodStart: start,
      spendablePerPeriodCents: 7_000,
      extraMoney: [
        ExtraMoneySnapshot(amountCents: 1_400, date: calendar.date(2026, 6, 5)),
        ExtraMoneySnapshot(amountCents: -700, date: calendar.date(2026, 6, 6)),
        ExtraMoneySnapshot(amountCents: 7_000, date: calendar.date(2026, 6, 8)),
      ]
    )
    let result = SpendingSummaryEngine(calendar: calendar).summary(
      budget: budget,
      expenses: [HistoryExpense(amountCents: 9_000, date: start, categoryID: 0)],
      view: .week,
      mode: .rolling,
      now: calendar.date(2026, 6, 7, 12)
    )
    // Three pre-budget days contribute zero; future extra money is excluded.
    #expect(result.budgetCents == 1_000 + 1_200 + 1_100 + 1_100)
    #expect(result.spentCents == 9_000)
  }

  @Test("Comparison labels match the selected view and boundaries")
  func comparisonLabels() {
    for mode in SpendingWindowMode.allCases {
      #expect(SpendingView.day.comparisonLabel(mode: mode) == "yesterday")
    }
    #expect(SpendingView.week.comparisonLabel(mode: .calendar) == "last week")
    #expect(SpendingView.week.comparisonLabel(mode: .rolling) == "previous 7 days")
    #expect(SpendingView.month.comparisonLabel(mode: .calendar) == "last month")
    #expect(SpendingView.month.comparisonLabel(mode: .rolling) == "previous 30 days")
  }

  @Test("AppStorage keys default to Day and Calendar and survive preference recreation")
  @MainActor
  func preferences() throws {
    let name = "SpendingSummaryTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let view = AppStorage(
      wrappedValue: SpendingPreferences.defaultView,
      SpendingPreferences.viewKey,
      store: defaults
    )
    let mode = AppStorage(
      wrappedValue: SpendingPreferences.defaultMode,
      SpendingPreferences.modeKey,
      store: defaults
    )
    #expect(SpendingPreferences.viewKey == "spendingView")
    #expect(SpendingPreferences.modeKey == "spendingWindowMode")
    #expect(view.wrappedValue == .day)
    #expect(mode.wrappedValue == .calendar)
    view.wrappedValue = .month
    mode.wrappedValue = .rolling
    let recreatedView = AppStorage(
      wrappedValue: SpendingPreferences.defaultView,
      SpendingPreferences.viewKey,
      store: defaults
    )
    let recreatedMode = AppStorage(
      wrappedValue: SpendingPreferences.defaultMode,
      SpendingPreferences.modeKey,
      store: defaults
    )
    #expect(recreatedView.wrappedValue == .month)
    #expect(recreatedMode.wrappedValue == .rolling)
  }

  @Test("Spending launch scenarios cover previous periods with visible increases")
  @MainActor
  func scenarios() throws {
    let now = calendar.date(2026, 6, 10, 12)
    for scenario in ScreenshotScenario.allCases where scenario.spendingSelection != nil {
      let selection = try #require(scenario.spendingSelection)
      let container = try RunwayModelContainer.make(inMemory: true)
      let context = ModelContext(container)
      let budget = try #require(try scenario.seed(into: context, now: now, calendar: calendar))
      let expenses = try context.fetch(FetchDescriptor<Expense>())
      let result = SpendingSummaryEngine(calendar: calendar).summary(
        budget: BudgetSnapshot(budget),
        expenses: expenses.map {
          HistoryExpense(amountCents: $0.amountCents, date: $0.date, categoryID: 0)
        },
        view: selection.view,
        mode: selection.mode,
        now: now
      )
      #expect(result.previousSpentCents > 0)
      #expect(try #require(result.percentageChange) > 0)
      #expect(result.budgetCents > 0)
      #expect(expenses.count == 70)
      #expect(scenario.todayDate != nil)
    }
  }
}
