import Foundation

// Mid-period schedule changes as pure value logic, shared by `Budget.updatePeriod` and the
// confirm dialog's preview.

extension BudgetSnapshot {
  /// The day a schedule edit at `now` is recorded from: today's local midnight. `nil` when no day
  /// has passed under the current schedule yet (before the budget starts, or a second edit on the
  /// day of the last change), so the edit simply replaces the current schedule.
  func scheduleEditDate(now: Date, calendar: Calendar) -> Date? {
    let today = calendar.startOfDay(for: now)
    let currentStart = scheduleChanges.last?.effectiveAt ?? calendar.startOfDay(for: periodStart)
    return today > currentStart ? today : nil
  }

  /// This budget with its schedule changed at `now`: the current period ends at the start of
  /// today and the new schedule applies from today. A second edit on the same day replaces the
  /// first, and one that restores the schedule from before today drops the change.
  func changingSchedule(
    to length: PeriodLength,
    start: Date,
    now: Date,
    calendar: Calendar
  ) -> BudgetSnapshot {
    let newStart = calendar.startOfDay(for: start)
    guard length != periodLength || newStart != periodStart else { return self }
    var result = self
    if let effectiveAt = scheduleEditDate(now: now, calendar: calendar) {
      result.scheduleChanges.append(
        ScheduleChangeSnapshot(
          previousPeriodLength: periodLength,
          previousPeriodStart: periodStart,
          effectiveAt: effectiveAt
        )
      )
    }
    result.periodLength = length
    result.periodStart = newStart
    if let last = result.scheduleChanges.last,
      last.effectiveAt == calendar.startOfDay(for: now),
      last.previousPeriodLength == length,
      last.previousPeriodStart == newStart
    {
      result.scheduleChanges.removeLast()
    }
    return result
  }
}

/// What changing the schedule today would do, for the confirm dialog.
struct ScheduleChangePreview: Equatable, Sendable {
  /// The period that ends when the new schedule starts today: the current one cut short, or the
  /// one that just ended if today was already a payday.
  var endingPeriod: BudgetPeriod
  /// What the ending period leaves: its (prorated) spendable + carry-in + extra − spent.
  var leftoverCents: Int
  /// Whether `leftoverCents` carries into the new period.
  var carriesOver: Bool
  /// The new schedule's first period, starting today.
  var newPeriod: BudgetPeriod
}

extension AllowanceEngine {
  /// What changing to `length` and `start` at `now` would do, or `nil` if no period has started
  /// yet, so nothing ends.
  func scheduleChangePreview(
    budget: BudgetSnapshot,
    expenses: [ExpenseSnapshot],
    length: PeriodLength,
    start: Date,
    now: Date
  ) -> ScheduleChangePreview? {
    let changed = budget.changingSchedule(to: length, start: start, now: now, calendar: calendar)
    let newPeriod = period(containing: now, of: changed)
    guard newPeriod.index > 0, newPeriod.start == calendar.startOfDay(for: now) else {
      return nil
    }
    let ending = period(at: newPeriod.index - 1, of: changed)
    let carryIn = carryInCents(to: ending, budget: changed, expenses: expenses)
    let leftover = carryOutCents(
      of: ending,
      budget: changed,
      expenses: expenses,
      carryInCents: carryIn
    )
    return ScheduleChangePreview(
      endingPeriod: ending,
      leftoverCents: leftover,
      carriesOver: isCarryoverEnabled(atBoundary: newPeriod.start, budget: changed),
      newPeriod: newPeriod
    )
  }
}
