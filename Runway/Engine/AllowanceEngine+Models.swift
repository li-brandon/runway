import Foundation
import SwiftData

// Maps the SwiftData models to the engine's value types so `AllowanceEngine` stays pure.

extension BudgetSnapshot {
  /// Includes the budget's carryover history, sorted by `effectiveAt` as the engine requires.
  init(_ budget: Budget) {
    let changes = budget.carryoverChanges.sorted { $0.effectiveAt < $1.effectiveAt }
    self.init(
      periodLength: budget.periodLength,
      periodStart: budget.periodStart,
      spendablePerPeriodCents: budget.spendablePerPeriodCents,
      carryoverEnabled: budget.carryoverEnabled,
      carryoverChanges: changes.map { CarryoverChangeSnapshot($0) }
    )
  }
}

extension CarryoverChangeSnapshot {
  init(_ change: CarryoverChange) {
    self.init(enabled: change.enabled, effectiveAt: change.effectiveAt)
  }
}

extension ExpenseSnapshot {
  init(_ expense: Expense) {
    self.init(amountCents: expense.amountCents, date: expense.date)
  }
}

extension Budget {
  /// Turns carryover on or off from the next period boundary after `now`, recording the change
  /// so the current period's carry-in stays as it was.
  ///
  /// Every recorded change flips the setting (see `AllowanceEngine`), so setting the current value
  /// does nothing, and switching back before the boundary cancels the pending change instead of
  /// recording a second one. That also keeps at most one change per boundary, so sorting by
  /// `effectiveAt` is unambiguous.
  func setCarryover(_ enabled: Bool, now: Date, calendar: Calendar) {
    guard enabled != carryoverEnabled else { return }
    carryoverEnabled = enabled

    let engine = AllowanceEngine(calendar: calendar)
    let boundary = engine.period(containing: now, of: BudgetSnapshot(self)).end
    if let pending = carryoverChanges.first(where: { $0.effectiveAt == boundary }) {
      carryoverChanges.removeAll { $0 === pending }
      modelContext?.delete(pending)
    } else {
      let change = CarryoverChange(enabled: enabled, effectiveAt: boundary)
      modelContext?.insert(change)
      carryoverChanges.append(change)
    }
  }
}
