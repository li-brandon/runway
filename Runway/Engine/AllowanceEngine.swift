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
///   so 23- and 25-hour DST days count as one day each. Pass the device's current calendar, so
///   the day boundary follows the time zone the user is in now.
/// - **Periods** are half-open `[start, end)` intervals of whole days. Period `n` starts at the
///   anchor (`calendar.startOfDay(for: budget.periodStart)`) plus `7n`/`14n` days or `n` months.
///   Months are always added to the anchor rather than chained, so a Jan 31 anchor gives Jan 31,
///   Feb 28, Mar 31, Apr 30… without drifting. Dates before the anchor belong to period 0.
/// - **Schedule changes** (period length or payday, `budget.scheduleChanges`) take effect at the
///   start of the day they were made. Days before follow the previous schedule, so the period
///   running then is cut short at `effectiveAt`. From `effectiveAt` the new schedule applies, and
///   its first period runs from `effectiveAt` to its next payday. Periods are numbered in order
///   across schedules. A period that is cut short or starts late keeps its full schedule in
///   `scheduledStart`/`scheduledEnd`.
/// - **Partial periods** get a prorated share of the money: `amount × days ÷ scheduled days`,
///   floor-divided, so changing the schedule never hands out a whole period's money for a few
///   days. A period cut short keeps its days' allowances as they were (they spread money over the
///   scheduled end), and its carry-out uses the prorated amount.
/// - **Daily allowance** = (spendable + carry-in + extra money through today − spent in the period
///   before today) ÷ days left including today. It is recomputed from scratch each day, so under-
///   or overspending is spread over the remaining days. Today's spending doesn't change today's
///   allowance; it reduces `remainingTodayCents`.
/// - **Amount changes** (`budget.amountChanges`) apply from the start of the day they were made.
///   Each day uses the amount in effect that day as the period's spendable, so past days keep the
///   allowance they had, and from today the period is planned with the new amount. A completed
///   period's carry-out uses the amount in effect on its last day.
/// - **Extra money** (one-off income, and bills skipped or paid at a different amount) counts from
///   its own day: it raises that day's allowance and the period's remainder, and never changes
///   earlier days. Extra money dated after today is ignored until its day arrives. Like expenses,
///   extra money dated before the budget's start belongs to no period, so it never counts.
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
///   (spendable + carry-in + extra money − everything spent in it, possibly negative) becomes the
///   next period's carry-in. With carryover off, every period starts fresh with a carry-in of 0,
///   which forgives overspending as well as dropping leftovers. Nothing is stored, so opening the
///   app after days or periods away catches up by chaining every period from the anchor.
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

    // Extra money counts through today, or through the period's end once it has ended.
    let extra = extraCents(in: period, budget: budget, before: max(todayStart, todayEnd))
    let spendable: Int
    let divisor: Int
    if todayStart < period.end {
      spendable = plannedSpendableCents(of: period, on: todayStart, budget: budget)
      divisor = max(1, dayCount(from: todayStart, to: period.scheduledEnd))
    } else {
      spendable = spendableCents(of: period, budget: budget)
      divisor = 1
    }
    let availableCents = spendable + carryInCents + extra - spentBeforeTodayCents
    let allowanceTodayCents = Self.floorDivide(availableCents, by: divisor)
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
      isOverBudget: remainingTodayCents < 0 || remainingPeriodCents < 0,
      extraCents: extra
    )
  }

  // MARK: - Period money

  /// The money for all of `period`: the amount in effect on `day` (clamped to the period's
  /// days), prorated if the period is shorter than its schedule.
  func spendableCents(of period: BudgetPeriod, on day: Date, budget: BudgetSnapshot) -> Int {
    let clamped = min(max(calendar.startOfDay(for: day), period.start), lastDay(of: period))
    let amount = budget.availableCents(on: clamped)
    return prorated(amount, from: period.start, to: period.end, of: period)
  }

  /// The money for all of a completed `period`, using the amount in effect on its last day. Its
  /// carry-out is based on this.
  func spendableCents(of period: BudgetPeriod, budget: BudgetSnapshot) -> Int {
    spendableCents(of: period, on: lastDay(of: period), budget: budget)
  }

  /// The money a day in `period` plans with, through the scheduled end: the amount in effect on
  /// `day`, prorated only for days the period lost at its start. A period later cut short by a
  /// schedule change therefore keeps the allowances its days had.
  func plannedSpendableCents(
    of period: BudgetPeriod,
    on day: Date,
    budget: BudgetSnapshot
  ) -> Int {
    let amount = budget.availableCents(on: calendar.startOfDay(for: day))
    return prorated(amount, from: period.start, to: period.scheduledEnd, of: period)
  }

  /// Extra money dated inside `period` and before `end`.
  func extraCents(in period: BudgetPeriod, budget: BudgetSnapshot, before end: Date) -> Int {
    budget.extraMoney.reduce(0) { total, extra in
      period.contains(extra.date) && extra.date < end ? total + extra.amountCents : total
    }
  }

  /// `cents × days(start, end) ÷ scheduled days of period`, or `cents` when they're equal.
  private func prorated(
    _ cents: Int,
    from start: Date,
    to end: Date,
    of period: BudgetPeriod
  ) -> Int {
    let scheduledDays = dayCount(from: period.scheduledStart, to: period.scheduledEnd)
    let days = dayCount(from: start, to: end)
    guard scheduledDays > 0, days != scheduledDays else { return cents }
    return Self.floorDivide(cents * days, by: scheduledDays)
  }

  // MARK: - Carryover

  /// What a completed period leaves behind: spendable + carry-in + extra money − everything
  /// spent in it. Negative when the period was overspent.
  func carryOutCents(
    of period: BudgetPeriod,
    budget: BudgetSnapshot,
    expenses: [ExpenseSnapshot],
    carryInCents: Int
  ) -> Int {
    let spentCents = expenses.reduce(0) { total, expense in
      period.contains(expense.date) ? total + expense.amountCents : total
    }
    let extra = extraCents(in: period, budget: budget, before: period.end)
    return spendableCents(of: period, budget: budget) + carryInCents + extra - spentCents
  }

  /// The carry-in for `period`, chaining every period from the anchor (period 0 has none).
  func carryInCents(
    to period: BudgetPeriod,
    budget: BudgetSnapshot,
    expenses: [ExpenseSnapshot]
  ) -> Int {
    guard period.index > 0 else { return 0 }
    let all = periods(of: budget) { $0.index >= period.index }
    var carryCents = 0
    for index in 1..<all.count {
      let carryOut = carryOutCents(
        of: all[index - 1],
        budget: budget,
        expenses: expenses,
        carryInCents: carryCents
      )
      let enabled = isCarryoverEnabled(atBoundary: all[index].start, budget: budget)
      carryCents = enabled ? carryOut : 0
    }
    return carryCents
  }

  /// The carryover setting applied when crossing into a period that starts at `boundary`.
  func isCarryoverEnabled(atBoundary boundary: Date, budget: BudgetSnapshot) -> Bool {
    let changes = budget.carryoverChanges
    guard let first = changes.first else { return budget.carryoverEnabled }
    return changes.last { $0.effectiveAt <= boundary }?.enabled ?? first.previousEnabled
  }

  /// The carryover change waiting for the next period boundary after `now`, if any.
  func pendingCarryoverChange(budget: BudgetSnapshot, now: Date) -> CarryoverChangeSnapshot? {
    let current = period(containing: now, of: budget)
    return budget.carryoverChanges.first { $0.effectiveAt > current.start }
  }

  // MARK: - Periods

  /// The `index`-th period after the anchor. `index` must not be negative.
  func period(at index: Int, of budget: BudgetSnapshot) -> BudgetPeriod {
    precondition(index >= 0, "index must not be negative")
    return periods(of: budget) { $0.index >= index }.last!
  }

  /// The period containing `date`. Dates before the anchor map to period 0.
  func period(containing date: Date, of budget: BudgetSnapshot) -> BudgetPeriod {
    periods(through: date, of: budget).last!
  }

  /// Every period from the anchor through the one containing `date`, oldest first. Never empty.
  func periods(through date: Date, of budget: BudgetSnapshot) -> [BudgetPeriod] {
    let day = calendar.startOfDay(for: date)
    return periods(of: budget) { day < $0.end }
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

  /// The last local day of `period`.
  func lastDay(of period: BudgetPeriod) -> Date {
    let previous = calendar.date(byAdding: .day, value: -1, to: period.end) ?? period.start
    return max(period.start, calendar.startOfDay(for: previous))
  }

  /// Local midnight of the day after the day starting at `dayStart`.
  func startOfNextDay(after dayStart: Date) -> Date {
    // `startOfDay` again in case local midnight doesn't exist on the next day.
    let next = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
    return calendar.startOfDay(for: next)
  }

  /// One pay schedule and the days it governs: `[start, end)`, or from `start` on when `end` is
  /// `nil` (the budget's live schedule).
  private struct Schedule {
    var length: PeriodLength
    /// Local midnight of the payday the schedule counts from.
    var anchor: Date
    var start: Date
    var end: Date?
  }

  /// The budget's schedules, oldest first. The first starts at its own anchor.
  private func schedules(of budget: BudgetSnapshot) -> [Schedule] {
    let firstAnchor = budget.scheduleChanges.first?.previousPeriodStart ?? budget.periodStart
    var start = calendar.startOfDay(for: firstAnchor)
    var result: [Schedule] = []
    for change in budget.scheduleChanges {
      let end = calendar.startOfDay(for: change.effectiveAt)
      result.append(
        Schedule(
          length: change.previousPeriodLength,
          anchor: calendar.startOfDay(for: change.previousPeriodStart),
          start: start,
          end: end
        )
      )
      start = max(start, end)
    }
    let anchor = calendar.startOfDay(for: budget.periodStart)
    result.append(Schedule(length: budget.periodLength, anchor: anchor, start: start, end: nil))
    return result
  }

  /// Every period from the anchor, oldest first, through the first one `isLast` accepts.
  /// `isLast` must eventually accept a period, or this never returns.
  private func periods(
    of budget: BudgetSnapshot,
    until isLast: (BudgetPeriod) -> Bool
  ) -> [BudgetPeriod] {
    var result: [BudgetPeriod] = []
    for schedule in schedules(of: budget) {
      var index = scheduleIndex(containing: schedule.start, of: schedule)
      while true {
        let scheduledStart = periodStart(index, of: schedule)
        let scheduledEnd = periodStart(index + 1, of: schedule)
        let start = max(scheduledStart, schedule.start)
        let end = schedule.end.map { min(scheduledEnd, $0) } ?? scheduledEnd
        guard start < end else { break }
        let period = BudgetPeriod(
          index: result.count,
          start: start,
          end: end,
          scheduledStart: scheduledStart,
          scheduledEnd: scheduledEnd
        )
        result.append(period)
        if isLast(period) { return result }
        if let scheduleEnd = schedule.end, end >= scheduleEnd { break }
        index += 1
      }
    }
    return result
  }

  /// The index, counted from the schedule's anchor and possibly negative, of the scheduled
  /// period containing the local day `day`.
  private func scheduleIndex(containing day: Date, of schedule: Schedule) -> Int {
    var index: Int
    if let daysPerPeriod = schedule.length.fixedDayCount {
      index = Self.floorDivide(dayCount(from: schedule.anchor, to: day), by: daysPerPeriod)
    } else {
      index = calendar.dateComponents([.month], from: schedule.anchor, to: day).month ?? 0
    }
    // Month math clamps to short months, so nudge the estimate until it brackets `day`.
    while periodStart(index, of: schedule) > day {
      index -= 1
    }
    while periodStart(index + 1, of: schedule) <= day {
      index += 1
    }
    return index
  }

  private func periodStart(_ index: Int, of schedule: Schedule) -> Date {
    let shifted: Date?
    if let daysPerPeriod = schedule.length.fixedDayCount {
      shifted = calendar.date(byAdding: .day, value: index * daysPerPeriod, to: schedule.anchor)
    } else {
      shifted = calendar.date(byAdding: .month, value: index, to: schedule.anchor)
    }
    return calendar.startOfDay(for: shifted ?? schedule.anchor)
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
  /// Anchor for the current schedule's periods. Only its local calendar day matters.
  var periodStart: Date
  /// The money spread over each period. For a persisted `Budget` this is its available amount
  /// (spendable − fixed bills − savings), not the raw spendable. Applies from the last of
  /// `amountChanges` on.
  var spendablePerPeriodCents: Int
  /// The current carryover setting. On by default. Only used when `carryoverChanges` is empty.
  var carryoverEnabled = true
  /// Every change to the carryover setting, sorted by `effectiveAt` (oldest first). The value
  /// before the first one is its `previousEnabled`.
  var carryoverChanges: [CarryoverChangeSnapshot] = []
  /// Every change to the per-period amount, sorted by `effectiveAt` (oldest first).
  var amountChanges: [AmountChangeSnapshot] = []
  /// Every change to the schedule, sorted by `effectiveAt` (oldest first). The first one's
  /// previous schedule is the budget's original one.
  var scheduleChanges: [ScheduleChangeSnapshot] = []
  /// One-off money and bill adjustments, in any order.
  var extraMoney: [ExtraMoneySnapshot] = []

  /// The per-period amount in effect on the local day starting at `day`.
  func availableCents(on day: Date) -> Int {
    amountChanges.first { $0.effectiveAt > day }?.previousCents ?? spendablePerPeriodCents
  }
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

/// A change to the per-period amount, made on the local day starting at `effectiveAt`.
struct AmountChangeSnapshot: Equatable, Sendable {
  /// The amount in effect on the days before `effectiveAt`.
  var previousCents: Int
  var effectiveAt: Date
}

/// A change to the period length or payday, made on the local day starting at `effectiveAt`.
struct ScheduleChangeSnapshot: Equatable, Sendable {
  var previousPeriodLength: PeriodLength
  var previousPeriodStart: Date
  var effectiveAt: Date
}

/// Money added to the period containing `date`, from that day on. Negative takes money away.
struct ExtraMoneySnapshot: Equatable, Sendable {
  var amountCents: Int
  var date: Date
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
  /// Where the period starts and ends on its pay schedule. They differ from `start` and `end`
  /// only when a schedule change cut the period short or started it partway through.
  var scheduledStart: Date
  var scheduledEnd: Date

  init(
    index: Int,
    start: Date,
    end: Date,
    scheduledStart: Date? = nil,
    scheduledEnd: Date? = nil
  ) {
    self.index = index
    self.start = start
    self.end = end
    self.scheduledStart = scheduledStart ?? start
    self.scheduledEnd = scheduledEnd ?? end
  }

  /// Shorter than its schedule because of a schedule change.
  var isPartial: Bool { start != scheduledStart || end != scheduledEnd }

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
  /// Spendable + carry-in + extra money − everything spent in the period through today.
  var remainingPeriodCents: Int
  /// Days left in the period including today; `0` once the period has ended.
  var daysLeft: Int
  var isOverBudget: Bool
  /// Extra money in the period through today.
  var extraCents = 0

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
