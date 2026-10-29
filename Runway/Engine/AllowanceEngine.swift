import Foundation

/// Computes how much the user can spend today. Pure value logic: Foundation only, no SwiftUI or
/// SwiftData (see `AllowanceEngine+Models.swift` for mapping from the persisted models).
///
/// Decisions:
/// - **Money** is integer cents. Divisions use floor division (round toward negative infinity) so
///   a daily figure is never overstated: `70_000 / 6` → `11_666`, `-5_001 / 5` → `-1_001`.
///   The leftover cents stay in the period and show up in later days' allowances.
/// - **Days** start at local midnight in `calendar.timeZone`. Day counts always come from
///   `calendar.startOfDay(for:)` and `dateComponents([.day], …)`, never from 86 400-second math,
///   so 23- and 25-hour DST days count as one day each.
/// - **Periods** are half-open `[start, end)` intervals of whole days. Period `n` starts at the
///   anchor (`calendar.startOfDay(for: budget.periodStart)`) plus `7n`/`14n` days or `n` months.
///   Months are always added to the anchor rather than chained, so a Jan 31 anchor gives Jan 31,
///   Feb 28, Mar 31, Apr 30… without drifting. Dates before the anchor belong to period 0.
/// - **Daily allowance** = (spendable + carry-in − spent in the period before today) ÷ days left
///   including today. It is recomputed from scratch each day, so under- or overspending is spread
///   over the remaining days. Today's spending doesn't change today's allowance; it reduces
///   `remainingTodayCents`.
/// - **Expenses** count only if their date is inside the period. Expenses dated after today are
///   ignored until their day arrives (but do count toward a completed period's carry-out).
///   Expenses dated before the budget's start (the anchor's local midnight) belong to no period,
///   so they never count, not even in the period-0 preview or its carry-out.
/// - **Days left** is clamped explicitly: before the period starts, the result previews its first
///   day; after it ends, `daysLeft` is `0`, nothing is "spent today", and the whole remainder is
///   today's allowance (the divisor is clamped to 1, so there is never a divide-by-zero).
/// - **Over budget** values go negative rather than clamping to zero, and set `isOverBudget`
///   when either today's or the period's remainder is below zero.
/// - **Carryover** (on by default in `BudgetSnapshot`): a completed period's carry-out
///   (spendable + carry-in − everything spent in it, possibly negative) becomes the next period's
///   carry-in. With carryover off, every period starts fresh with a carry-in of 0, which forgives
///   overspending as well as dropping leftovers.
/// - **Changing the carryover setting** takes effect at the next period boundary. The setting is
///   evaluated once per boundary, when crossing into a new period: it is the `enabled` value of
///   the last of `budget.carryoverChanges` whose `effectiveAt` is at or before the boundary, so a
///   change effective exactly at a boundary applies at that boundary. Boundaries before the first
///   change use its recorded `previousEnabled`; with no changes, every boundary uses
///   `budget.carryoverEnabled`. Turning carryover off mid-period therefore keeps the current
///   period's carry-in and only zeroes the next one.
/// - **Spendable** here is whatever the caller passes as `spendablePerPeriodCents`. The adapter
///   for the persisted `Budget` passes its available amount (spendable − fixed bills − savings),
///   so bills and savings never count as day-to-day money.
struct AllowanceEngine: Sendable {
  let calendar: Calendar

  // MARK: - Allowance

  /// Today's allowance for the period containing `now`, chaining carryover from the anchor.
  func currentAllowance(
    budget: BudgetSnapshot,
    expenses: [ExpenseSnapshot],
    now: Date
  ) -> AllowanceResult {
    let current = period(containing: now, of: budget)
    let carryIn = carryInCents(to: current, budget: budget, expenses: expenses)
    return allowance(
      in: current,
      budget: budget,
      expenses: expenses,
      carryInCents: carryIn,
      now: now
    )
  }

  /// Today's allowance for the period containing `now`, with a known carry-in.
  func allowance(
    budget: BudgetSnapshot,
    expenses: [ExpenseSnapshot],
    carryInCents: Int,
    now: Date
  ) -> AllowanceResult {
    allowance(
      in: period(containing: now, of: budget),
      budget: budget,
      expenses: expenses,
      carryInCents: carryInCents,
      now: now
    )
  }

  /// Today's allowance within `period`. `now` may fall outside it; see the type's documentation.
  func allowance(
    in period: BudgetPeriod,
    budget: BudgetSnapshot,
    expenses: [ExpenseSnapshot],
    carryInCents: Int,
    now: Date
  ) -> AllowanceResult {
    // Before the period, preview its first day. After it, `todayEnd <= todayStart`, so no expense
    // counts as today's and everything in the period counts as spent before today.
    let todayStart = max(calendar.startOfDay(for: now), period.start)
    let todayEnd = min(startOfNextDay(after: todayStart), period.end)
    let daysLeft = max(0, dayCount(from: todayStart, to: period.end))

    var spentBeforeTodayCents = 0
    var spentTodayCents = 0
    for expense in expenses where period.contains(expense.date) {
      if expense.date < todayStart {
        spentBeforeTodayCents += expense.amountCents
      } else if expense.date < todayEnd {
        spentTodayCents += expense.amountCents
      }
    }

    let availableCents = budget.spendablePerPeriodCents + carryInCents - spentBeforeTodayCents
    let allowanceTodayCents = Self.floorDivide(availableCents, by: max(daysLeft, 1))
    let remainingTodayCents = allowanceTodayCents - spentTodayCents
    let remainingPeriodCents = availableCents - spentTodayCents
    return AllowanceResult(
      period: period,
      carryInCents: carryInCents,
      allowanceTodayCents: allowanceTodayCents,
      spentTodayCents: spentTodayCents,
      remainingTodayCents: remainingTodayCents,
      remainingPeriodCents: remainingPeriodCents,
      daysLeft: daysLeft,
      isOverBudget: remainingTodayCents < 0 || remainingPeriodCents < 0
    )
  }

  // MARK: - Carryover

  /// What a completed period leaves behind: spendable + carry-in − everything spent in it.
  /// Negative when the period was overspent.
  func carryOutCents(
    of period: BudgetPeriod,
    budget: BudgetSnapshot,
    expenses: [ExpenseSnapshot],
    carryInCents: Int
  ) -> Int {
    let spentCents = expenses.reduce(0) { total, expense in
      period.contains(expense.date) ? total + expense.amountCents : total
    }
    return budget.spendablePerPeriodCents + carryInCents - spentCents
  }

  /// The carry-in for `period`, chaining every period from the anchor (period 0 has none).
  func carryInCents(
    to period: BudgetPeriod,
    budget: BudgetSnapshot,
    expenses: [ExpenseSnapshot]
  ) -> Int {
    guard period.index > 0 else { return 0 }
    var carryCents = 0
    var previous = self.period(at: 0, of: budget)
    for index in 1...period.index {
      let next = self.period(at: index, of: budget)
      let carryOut = carryOutCents(
        of: previous,
        budget: budget,
        expenses: expenses,
        carryInCents: carryCents
      )
      let enabled = isCarryoverEnabled(atBoundary: next.start, budget: budget)
      carryCents = enabled ? carryOut : 0
      previous = next
    }
    return carryCents
  }

  /// The carryover setting applied when crossing into a period that starts at `boundary`.
  func isCarryoverEnabled(atBoundary boundary: Date, budget: BudgetSnapshot) -> Bool {
    let changes = budget.carryoverChanges
    guard let first = changes.first else { return budget.carryoverEnabled }
    return changes.last { $0.effectiveAt <= boundary }?.enabled ?? first.previousEnabled
  }

  // MARK: - Periods

  /// The `index`-th period after the anchor.
  func period(at index: Int, of budget: BudgetSnapshot) -> BudgetPeriod {
    BudgetPeriod(
      index: index,
      start: periodStart(index, of: budget),
      end: periodStart(index + 1, of: budget)
    )
  }

  /// The period containing `date`. Dates before the anchor map to period 0.
  func period(containing date: Date, of budget: BudgetSnapshot) -> BudgetPeriod {
    let anchor = calendar.startOfDay(for: budget.periodStart)
    let day = calendar.startOfDay(for: date)
    guard day > anchor else { return period(at: 0, of: budget) }

    var index: Int
    if let daysPerPeriod = budget.periodLength.fixedDayCount {
      index = Self.floorDivide(dayCount(from: anchor, to: day), by: daysPerPeriod)
    } else {
      index = calendar.dateComponents([.month], from: anchor, to: day).month ?? 0
    }
    // Month math clamps to short months, so nudge the estimate until it brackets `day`.
    while index > 0 && periodStart(index, of: budget) > day {
      index -= 1
    }
    while periodStart(index + 1, of: budget) <= day {
      index += 1
    }
    return period(at: index, of: budget)
  }

  /// Whole calendar days from the day containing `start` to the day containing `end`.
  func dayCount(from start: Date, to end: Date) -> Int {
    let components = calendar.dateComponents(
      [.day],
      from: calendar.startOfDay(for: start),
      to: calendar.startOfDay(for: end)
    )
    return components.day ?? 0
  }

  private func periodStart(_ index: Int, of budget: BudgetSnapshot) -> Date {
    let anchor = calendar.startOfDay(for: budget.periodStart)
    let shifted: Date?
    if let daysPerPeriod = budget.periodLength.fixedDayCount {
      shifted = calendar.date(byAdding: .day, value: index * daysPerPeriod, to: anchor)
    } else {
      shifted = calendar.date(byAdding: .month, value: index, to: anchor)
    }
    return calendar.startOfDay(for: shifted ?? anchor)
  }

  private func startOfNextDay(after dayStart: Date) -> Date {
    // `startOfDay` again in case local midnight doesn't exist on the next day.
    let next = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
    return calendar.startOfDay(for: next)
  }

  // MARK: - Arithmetic

  /// Integer division rounding toward negative infinity. `divisor` must be positive.
  static func floorDivide(_ dividend: Int, by divisor: Int) -> Int {
    precondition(divisor > 0, "divisor must be positive")
    let quotient = dividend / divisor
    return dividend % divisor < 0 ? quotient - 1 : quotient
  }
}

// MARK: - Inputs

/// The budget fields the engine needs.
struct BudgetSnapshot: Equatable, Sendable {
  var periodLength: PeriodLength
  /// Anchor for period 0. Only its local calendar day matters.
  var periodStart: Date
  /// The money spread over each period. For a persisted `Budget` this is its available amount
  /// (spendable − fixed bills − savings), not the raw spendable.
  var spendablePerPeriodCents: Int
  /// The current carryover setting. On by default. Only used when `carryoverChanges` is empty.
  var carryoverEnabled = true
  /// Every change to the carryover setting, sorted by `effectiveAt` (oldest first). The value
  /// before the first one is its `previousEnabled`.
  var carryoverChanges: [CarryoverChangeSnapshot] = []
}

/// The expense fields the engine needs.
struct ExpenseSnapshot: Equatable, Sendable {
  var amountCents: Int
  var date: Date
}

/// A change to the carryover setting. It applies from the first period boundary at or after
/// `effectiveAt`.
struct CarryoverChangeSnapshot: Equatable, Sendable {
  var enabled: Bool
  /// The setting in effect before this change.
  var previousEnabled: Bool
  var effectiveAt: Date
}

// MARK: - Outputs

/// One budgeting period: the half-open interval `[start, end)` of whole local days.
struct BudgetPeriod: Equatable, Sendable {
  /// 0 for the period starting at the budget's anchor.
  var index: Int
  /// Local midnight of the first day.
  var start: Date
  /// Local midnight of the day after the last day (the next period's `start`).
  var end: Date

  func contains(_ date: Date) -> Bool {
    start <= date && date < end
  }
}

/// Today's spending picture. Values are integer cents and go negative when overspent.
struct AllowanceResult: Equatable, Sendable {
  var period: BudgetPeriod
  var carryInCents: Int
  /// What can be spent today, fixed at the start of the day.
  var allowanceTodayCents: Int
  var spentTodayCents: Int
  /// `allowanceTodayCents - spentTodayCents`.
  var remainingTodayCents: Int
  /// Spendable + carry-in − everything spent in the period through today.
  var remainingPeriodCents: Int
  /// Days left in the period including today; `0` once the period has ended.
  var daysLeft: Int
  var isOverBudget: Bool

  var periodStart: Date { period.start }
  var periodEnd: Date { period.end }
}

extension PeriodLength {
  /// Days per period, or `nil` for calendar months.
  var fixedDayCount: Int? {
    switch self {
    case .weekly: 7
    case .biweekly: 14
    case .monthly: nil
    }
  }
}
