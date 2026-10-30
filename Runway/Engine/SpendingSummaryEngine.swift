import Foundation

enum SpendingView: String, CaseIterable, Sendable {
  case day = "Day"
  case week = "Week"
  case month = "Month"

  func heading(mode: SpendingWindowMode) -> String {
    switch self {
    case .day: return "Spent this day"
    case .week: return mode == .rolling ? "Spent in the last 7 days" : "Spent this week"
    case .month: return mode == .rolling ? "Spent in the last 30 days" : "Spent this month"
    }
  }

  func comparisonLabel(mode: SpendingWindowMode) -> String {
    switch self {
    case .day: return "yesterday"
    case .week: return mode == .rolling ? "previous 7 days" : "last week"
    case .month: return mode == .rolling ? "previous 30 days" : "last month"
    }
  }
}

enum SpendingWindowMode: String, CaseIterable, Sendable {
  case calendar = "Calendar"
  case rolling = "Rolling"
}

enum SpendingPreferences {
  static let viewKey = "spendingView"
  static let modeKey = "spendingWindowMode"
  static let defaultView = SpendingView.day
  static let defaultMode = SpendingWindowMode.calendar
}

struct SpendingWindow: Equatable, Sendable {
  var start: Date
  var end: Date

  func contains(_ date: Date) -> Bool { date >= start && date < end }
}

struct SpendingSummary: Equatable, Sendable {
  var window: SpendingWindow
  var previousWindow: SpendingWindow
  var spentCents: Int
  var previousSpentCents: Int
  var budgetCents: Int

  /// Absolute denominator keeps increases positive even when the previous total is a refund.
  /// A zero baseline has no meaningful percentage (including when both totals are zero).
  var percentageChange: Double? {
    guard previousSpentCents != 0 else { return nil }
    return (Double(spentCents) - Double(previousSpentCents))
      / abs(Double(previousSpentCents)) * 100
  }
}

/// Calendar slices run through today, compared with the same elapsed number of days in the
/// previous calendar period, capped at that period's end (e.g. March 31 compares with February).
/// Rolling slices include today and the preceding 6/29 days; comparison is the preceding slice.
/// All intervals are half-open local days. Future expenses and days before budget start are
/// excluded. Budget slice sums each day's period spendable plus extra money through that day,
/// divided by the period's day count, floor-divided in cents. Carryover and spending are excluded.
struct SpendingSummaryEngine: Sendable {
  let calendar: Calendar

  func windows(
    view: SpendingView,
    mode: SpendingWindowMode,
    now: Date
  ) -> (current: SpendingWindow, previous: SpendingWindow) {
    let today = calendar.startOfDay(for: now)
    let end = calendar.date(byAdding: .day, value: 1, to: today)!
    let count = view == .month ? 30 : 7
    if view == .day || mode == .rolling {
      let days = view == .day ? 1 : count
      let start = calendar.date(byAdding: .day, value: -days, to: end)!
      let previousStart = calendar.date(byAdding: .day, value: -days, to: start)!
      return (
        SpendingWindow(start: start, end: end),
        SpendingWindow(start: previousStart, end: start)
      )
    }
    let component: Calendar.Component = view == .week ? .weekOfYear : .month
    let start = calendar.dateInterval(of: component, for: today)!.start
    let before = calendar.date(byAdding: .day, value: -1, to: start)!
    let previousStart = calendar.dateInterval(of: component, for: before)!.start
    let elapsed = calendar.dateComponents([.day], from: start, to: end).day!
    let previousEnd = calendar.date(byAdding: .day, value: elapsed, to: previousStart)!
    return (
      SpendingWindow(start: start, end: end),
      SpendingWindow(start: previousStart, end: min(start, previousEnd))
    )
  }

  func summary<CategoryID: Hashable & Sendable>(
    budget: BudgetSnapshot,
    expenses: [HistoryExpense<CategoryID>],
    view: SpendingView,
    mode: SpendingWindowMode,
    now: Date
  ) -> SpendingSummary {
    let windows = windows(view: view, mode: mode, now: now)
    let engine = AllowanceEngine(calendar: calendar)
    let periods = HistoryEngine(calendar: calendar).periods(
      budget: budget,
      expenses: expenses,
      now: now
    )
    let days = periods.flatMap(\.days)
    var budgetCents = 0
    for history in periods {
      let period = history.period
      let periodDays = max(1, engine.dayCount(from: period.start, to: period.end))
      for day in history.days where windows.current.contains(day.date) {
        let spendable = engine.spendableCents(
          of: period,
          on: day.date,
          budget: budget
        )
        let extra = engine.extraCents(
          in: period,
          budget: budget,
          before: engine.startOfNextDay(after: day.date)
        )
        budgetCents += AllowanceEngine.floorDivide(spendable + extra, by: periodDays)
      }
    }
    let current = days.filter { windows.current.contains($0.date) }
    let previous = days.filter { windows.previous.contains($0.date) }
    return SpendingSummary(
      window: windows.current,
      previousWindow: windows.previous,
      spentCents: current.reduce(0) { $0 + $1.spentCents },
      previousSpentCents: previous.reduce(0) { $0 + $1.spentCents },
      budgetCents: budgetCents
    )
  }
}
