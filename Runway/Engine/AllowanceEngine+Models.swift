import Foundation
import SwiftData

// Maps the SwiftData models to the engine's value types so `AllowanceEngine` stays pure.

extension BudgetSnapshot {
  /// Uses the budget's available amount (spendable − fixed bills − savings) as the per-period
  /// money, and includes its carryover history sorted by `effectiveAt` as the engine requires.
  init(_ budget: Budget) {
    let changes = budget.carryoverChanges.sorted { $0.effectiveAt < $1.effectiveAt }
    self.init(
      periodLength: budget.periodLength,
      periodStart: budget.periodStart,
      spendablePerPeriodCents: budget.availablePerPeriodCents,
      carryoverEnabled: budget.carryoverEnabled,
      carryoverChanges: changes.map { CarryoverChangeSnapshot($0) }
    )
  }
}

extension CarryoverChangeSnapshot {
  init(_ change: CarryoverChange) {
    self.init(
      enabled: change.enabled,
      previousEnabled: change.previousEnabled,
      effectiveAt: change.effectiveAt
    )
  }
}

extension ExpenseSnapshot {
  init(_ expense: Expense) {
    self.init(amountCents: expense.amountCents, date: expense.date)
  }
}

extension Budget {
  /// What each period leaves for day-to-day spending: spendable − fixed bills − savings. Can be
  /// zero or negative.
  var availablePerPeriodCents: Int {
    spendablePerPeriodCents - fixedBills.reduce(0) { $0 + $1.amountCents } - savingsCents
  }

  /// Turns carryover on or off from the next period boundary after `now`, recording the change
  /// so the current period's carry-in stays as it was.
  ///
  /// Setting the value already set does nothing. Switching back before the boundary cancels the
  /// pending change instead of recording a second one, so there is at most one pending change and
  /// at most one change per boundary, which keeps sorting by `effectiveAt` unambiguous.
  func setCarryover(_ enabled: Bool, now: Date, calendar: Calendar) {
    guard enabled != carryoverEnabled else { return }
    let previous = carryoverEnabled
    carryoverEnabled = enabled
    reschedulePendingCarryoverChange(now: now, calendar: calendar, previousSetting: previous)
  }

  /// Changes the period length and start (payday). A pending carryover change moves to the new
  /// next boundary after `now`, or is dropped if the setting in effect already matches it.
  func updatePeriod(_ length: PeriodLength, start: Date, now: Date, calendar: Calendar) {
    guard length != periodLength || start != periodStart else { return }
    periodLength = length
    periodStart = start
    reschedulePendingCarryoverChange(
      now: now,
      calendar: calendar,
      previousSetting: carryoverEnabled
    )
  }

  /// Leaves at most one pending change, at the next boundary after `now`, taking the setting
  /// from the one in effect to `carryoverEnabled`.
  ///
  /// A change is pending if it hasn't applied by the start of the period containing `now`, judged
  /// by the current schedule (a period change can turn an applied change back into a pending
  /// one). The setting in effect comes from the last applied change, else the first pending
  /// change's `previousEnabled`, else `previousSetting` when there is no history at all.
  private func reschedulePendingCarryoverChange(
    now: Date,
    calendar: Calendar,
    previousSetting: Bool
  ) {
    let engine = AllowanceEngine(calendar: calendar)
    let current = engine.period(containing: now, of: BudgetSnapshot(self))
    let sorted = carryoverChanges.sorted { $0.effectiveAt < $1.effectiveAt }
    let applied = sorted.filter { $0.effectiveAt <= current.start }
    let pending = sorted.filter { $0.effectiveAt > current.start }
    let inEffect = applied.last?.enabled ?? pending.first?.previousEnabled ?? previousSetting

    let kept = carryoverEnabled != inEffect ? pending.first : nil
    for change in pending where change !== kept {
      carryoverChanges.removeAll { $0 === change }
      modelContext?.delete(change)
    }
    guard carryoverEnabled != inEffect else { return }

    if let kept {
      kept.enabled = carryoverEnabled
      kept.previousEnabled = inEffect
      kept.effectiveAt = current.end
    } else {
      let change = CarryoverChange(
        enabled: carryoverEnabled,
        previousEnabled: inEffect,
        effectiveAt: current.end
      )
      modelContext?.insert(change)
      carryoverChanges.append(change)
    }
  }
}
