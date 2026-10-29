import Foundation
import SwiftData

// Maps the SwiftData models to the engine's value types so `AllowanceEngine` stays pure.

extension BudgetSnapshot {
  /// Schema V1 stores only the current carryover setting, not its history, so callers that need
  /// "applies from the next period" semantics must also pass `CarryoverChange`s to the engine.
  init(_ budget: Budget) {
    self.init(
      periodLength: budget.periodLength,
      periodStart: budget.periodStart,
      spendablePerPeriodCents: budget.spendablePerPeriodCents,
      carryoverEnabled: budget.carryoverEnabled
    )
  }
}

extension ExpenseSnapshot {
  init(_ expense: Expense) {
    self.init(amountCents: expense.amountCents, date: expense.date)
  }
}
