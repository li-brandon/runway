import Foundation

/// Decides when a widget's figures change and works them out ahead of time, so they roll over
/// without the app running. Works only from its arguments, so tests can inject the calendar.
struct WidgetTimelinePlanner: Sendable {
  let calendar: Calendar

  /// The moments to show new figures: now, the start or end of `period` if either comes before the
  /// next midnight, and that midnight. Oldest first, with no repeats.
  func entryDates(now: Date, period: BudgetPeriod) -> [Date] {
    let midnight = nextMidnight(after: now, calendar: calendar)
    let boundaries = [period.start, period.end].filter { now < $0 && $0 < midnight }
    return [now] + boundaries + [midnight]
  }

  /// An entry from `AllowanceEngine` for each of `entryDates`, reloading at the next midnight.
  func plan(
    budget: BudgetSnapshot,
    expenses: [ExpenseSnapshot],
    amountsArePrivate: Bool,
    now: Date
  ) -> WidgetTimelinePlan {
    let engine = AllowanceEngine(calendar: calendar)
    let period = engine.period(containing: now, of: budget)
    let entries = entryDates(now: now, period: period).map { date in
      let result = engine.currentAllowance(budget: budget, expenses: expenses, now: date)
      return RunwayWidgetEntry(
        date: date,
        content: .allowance(WidgetAllowance(result)),
        amountsArePrivate: amountsArePrivate
      )
    }
    return WidgetTimelinePlan(
      entries: entries,
      reloadDate: nextMidnight(after: now, calendar: calendar)
    )
  }
}
