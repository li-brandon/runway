import Foundation

enum SpendingView: String, CaseIterable, Sendable {
  case day = "Day"
  case week = "Week"
  case month = "Month"
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
/// excluded. Budget slice = sum of History's start-of-day allowances for the included days,
/// including dated amount/schedule changes, carryover, extra money and earlier net spending.
/// This is a sum of daily opportunities to spend, not a separate allocation of period income.
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
    let days = HistoryEngine(calendar: calendar).periods(
      budget: budget,
      expenses: expenses,
      now: now
    ).flatMap(\.days)
    let current = days.filter { windows.current.contains($0.date) }
    let previous = days.filter { windows.previous.contains($0.date) }
    return SpendingSummary(
      window: windows.current,
      previousWindow: windows.previous,
      spentCents: current.reduce(0) { $0 + $1.spentCents },
      previousSpentCents: previous.reduce(0) { $0 + $1.spentCents },
      budgetCents: current.reduce(0) { $0 + $1.allowanceCents }
    )
  }
}
