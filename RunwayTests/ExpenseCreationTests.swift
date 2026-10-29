import Foundation
import SwiftData
import Testing

@testable import Runway

/// Allows raw model fixtures, including legacy rows with no category.
func makeFixtureExpense(
  amountCents: Int,
  note: String = "",
  date: Date = .now,
  createdAt: Date = .now
) -> Expense {
  #if DEBUG
    return ExpenseCreationGuard.$isAuthorized.withValue(true) {
      Expense(amountCents: amountCents, note: note, date: date, createdAt: createdAt)
    }
  #else
    return Expense(amountCents: amountCents, note: note, date: date, createdAt: createdAt)
  #endif
}

#if DEBUG
  struct ExpenseCreationTests {
    @Test("Only scoped expense creation is authorized")
    func creationAuthorization() throws {
      // This is the predicate used by Expense.init; do not trigger the assertion.
      #expect(!ExpenseCreationGuard.isAuthorized)
      let container = try RunwayModelContainer.make(inMemory: true)
      let context = ModelContext(container)
      let expense = try CategoryService(context: context).createExpense(amountCents: 125)
      #expect(expense.creationWasAuthorized)
      #expect(!ExpenseCreationGuard.isAuthorized)
    }
  }
#endif
