import Foundation

/// Builds History's day rows and period summaries from the budget and expenses alone. Pure value
/// logic like `AllowanceEngine`, whose period, day, carryover, and rounding rules it reuses; see
/// `AllowanceEngine+Models.swift` for mapping from the persisted models.
///
/// Decisions:
/// - **Nothing is stored.** Every figure is derived from the expenses on each call, so an edit or
///   delete changes later days, carryover, and Today the next time anything renders.
/// - **Day rows** match `AllowanceEngine.allowance(in:…)` evaluated on that day: the allowance is
///   (spendable in effect that day + carry-in + extra money through the day − spent in the period
///   before the day) ÷ days left including the day, floor-divided. Over/under is that allowance
///   minus the day's spending. So a mid-period amount change, extra money, or a schedule change
///   leaves the rows before it as they were.
/// - **Partial periods** (cut short or started late by a schedule change) show their prorated
///   money in the summary, which is what their carry-out is based on.
/// - **Periods** run from period 0 to the period containing `now`, newest first. Each lists its
///   days from the first through today (all days for a completed period), newest first.
/// - **Spending** in a completed period counts every expense in it, as its carry-out does. The
///   current period counts expenses through the end of today; later-dated ones are ignored until
///   their day arrives, as on Today. Expenses before the budget's start belong to no period.
/// - **Carryover** chains like `AllowanceEngine.carryInCents`: a completed period's carry-out is
///   its remainder if carryover is on at the next boundary, otherwise 0. The current period has no
///   carry-out yet.
/// - **Days over** counts day rows whose spending exceeds their allowance, including today.
/// - **Cost** is one sort plus one sweep over the days, O(n log n + days), rather than one
///   `AllowanceEngine` call per day or period.
struct HistoryEngine: Sendable {
  let calendar: Calendar

  /// Every period from the budget's start through the one containing `now`, newest first. Never
  /// empty.
  func periods<CategoryID: Hashable & Sendable>(
    budget: BudgetSnapshot,
    expenses: [HistoryExpense<CategoryID>],
    now: Date
  ) -> [HistoryPeriod<CategoryID>] {
    let engine = AllowanceEngine(calendar: calendar)
    let all = engine.periods(through: now, of: budget)
    let todayStart = calendar.startOfDay(for: now)
    let anchor = all[0].start
    let sorted = expenses.filter { $0.date >= anchor }.sorted { $0.date < $1.date }
    let extras = budget.extraMoney.filter { $0.date >= anchor }.sorted { $0.date < $1.date }

    var cursor = 0
    var extraCursor = 0
    var carryInCents = 0
    var result: [HistoryPeriod<CategoryID>] = []
    result.reserveCapacity(all.count)
    for period in all {
      let isCurrent = period.index == all.count - 1
      let periodCarryInCents = carryInCents

      var days: [HistoryDay] = []
      var spentCents = 0
      var extraCents = 0
      var categoryCents: [CategoryID: Int] = [:]
      var categoryOrder: [CategoryID] = []
      var day = period.start
      while day < period.end {
        let next = engine.startOfNextDay(after: day)
        guard next > day else { break }
        let counts = day <= todayStart
        // Extra money counts from its own day, including toward that day's allowance.
        while extraCursor < extras.count, extras[extraCursor].date < next {
          if counts { extraCents += extras[extraCursor].amountCents }
          extraCursor += 1
        }
        var spentDayCents = 0
        while cursor < sorted.count, sorted[cursor].date < next {
          let expense = sorted[cursor]
          cursor += 1
          guard counts else { continue }
          spentDayCents += expense.amountCents
          if categoryCents[expense.categoryID] == nil {
            categoryOrder.append(expense.categoryID)
          }
          categoryCents[expense.categoryID, default: 0] += expense.amountCents
        }
        if counts {
          let plannedCents = engine.plannedSpendableCents(of: period, on: day, budget: budget)
          let daysLeft = max(1, engine.dayCount(from: day, to: period.scheduledEnd))
          let allowanceCents = AllowanceEngine.floorDivide(
            plannedCents + periodCarryInCents + extraCents - spentCents,
            by: daysLeft
          )
          days.append(
            HistoryDay(
              date: day,
              allowanceCents: allowanceCents,
              spentCents: spentDayCents,
              isToday: day == todayStart
            )
          )
        }
        spentCents += spentDayCents
        day = next
      }

      // The current period plans with today's amount; a completed one with its last day's.
      let spendableCents = engine.spendableCents(
        of: period,
        on: isCurrent ? todayStart : engine.lastDay(of: period),
        budget: budget
      )
      let remainingCents = spendableCents + periodCarryInCents + extraCents - spentCents
      var carryOutCents: Int?
      if !isCurrent {
        let enabled = engine.isCarryoverEnabled(atBoundary: period.end, budget: budget)
        carryOutCents = enabled ? remainingCents : 0
        carryInCents = enabled ? remainingCents : 0
      }
      // Sort the first-spending order by amount, using the order to break ties.
      let ranked = categoryOrder.enumerated().sorted { lhs, rhs in
        let left = categoryCents[lhs.element]!
        let right = categoryCents[rhs.element]!
        if left != right { return left > right }
        return lhs.offset < rhs.offset
      }
      let categories = ranked.map { item in
        HistoryCategoryTotal(categoryID: item.element, spentCents: categoryCents[item.element]!)
      }
      let enabledAtStart = engine.isCarryoverEnabled(atBoundary: period.start, budget: budget)

      result.append(
        HistoryPeriod(
          period: period,
          isCurrent: isCurrent,
          carryoverEnabledAtStart: enabledAtStart,
          spendableCents: spendableCents,
          carryInCents: periodCarryInCents,
          extraCents: extraCents,
          spentCents: spentCents,
          carryOutCents: carryOutCents,
          days: days.reversed(),
          categories: categories
        )
      )
    }
    return result.reversed()
  }

  /// Groups items inside `period` by the local day of `date`, keeping their order. Items outside
  /// the period are skipped without any calendar work.
  func itemsByDay<Item>(
    _ items: [Item],
    in period: BudgetPeriod,
    date: (Item) -> Date
  ) -> [Date: [Item]] {
    var result: [Date: [Item]] = [:]
    for item in items {
      let itemDate = date(item)
      guard period.contains(itemDate) else { continue }
      result[calendar.startOfDay(for: itemDate), default: []].append(item)
    }
    return result
  }

  /// The last local day of `period`, for display.
  func lastDay(of period: BudgetPeriod) -> Date {
    AllowanceEngine(calendar: calendar).lastDay(of: period)
  }
}

// MARK: - Inputs

/// The expense fields History needs. `CategoryID` is the persistent ID in the app and any
/// hashable value in tests.
struct HistoryExpense<CategoryID: Hashable & Sendable>: Equatable, Sendable {
  var amountCents: Int
  var date: Date
  var categoryID: CategoryID
}

// MARK: - Outputs

/// One day of a period. Values are integer cents.
struct HistoryDay: Equatable, Sendable {
  /// Local midnight.
  var date: Date
  /// What could be spent that day, fixed at the start of the day.
  var allowanceCents: Int
  /// Net spending that day; refunds reduce it.
  var spentCents: Int
  var isToday: Bool

  /// Allowance minus spending: negative when the day went over.
  var remainingCents: Int { allowanceCents - spentCents }
  var isOver: Bool { remainingCents < 0 }
}

/// Net spending in one category over a period. Negative when refunds outweigh spending.
struct HistoryCategoryTotal<CategoryID: Hashable & Sendable>: Equatable, Sendable {
  var categoryID: CategoryID
  var spentCents: Int
}

/// A period's day rows and summary.
struct HistoryPeriod<CategoryID: Hashable & Sendable>: Equatable, Sendable {
  var period: BudgetPeriod
  /// The period containing `now`; its figures run through today.
  var isCurrent: Bool
  /// Whether carryover applied when entering this period (as Today's carry-in line uses).
  var carryoverEnabledAtStart: Bool
  /// The period's money: prorated if a schedule change made it partial, and as of today (current)
  /// or its last day (completed) if the amount changed.
  var spendableCents: Int
  var carryInCents: Int
  /// Extra money (one-off income and bill adjustments) through today.
  var extraCents: Int
  var spentCents: Int
  /// What the next period receives: the remainder, or 0 with carryover off at the next boundary.
  /// `nil` while the period is in progress.
  var carryOutCents: Int?
  /// Newest first.
  var days: [HistoryDay]
  /// Highest net spending first; ties keep the order of first spending.
  var categories: [HistoryCategoryTotal<CategoryID>]

  /// Spendable plus carry-in plus extra money.
  var availableCents: Int { spendableCents + carryInCents + extraCents }
  /// Available minus spent: negative when the period went over.
  var remainingCents: Int { availableCents - spentCents }
  var daysOver: Int { days.reduce(0) { $1.isOver ? $0 + 1 : $0 } }
}
