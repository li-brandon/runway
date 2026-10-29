import Foundation
import SwiftData
import Testing

@testable import Runway

/// Carryover through the `Budget` model and its `CarryoverChange` history. Weekly $700 budget
/// anchored Monday 2026-06-01 in Chicago. Period 0 (Jun 1–7) spends $500, leaving +$200.
/// Period 1 (Jun 8–14) spends $1,000.
struct BudgetCarryoverTests {
  let calendar = Calendar.gregorian("America/Chicago")
  let engine: AllowanceEngine
  let expenses: [ExpenseSnapshot]
  let container: ModelContainer

  init() throws {
    engine = AllowanceEngine(calendar: calendar)
    expenses = [
      expense(50_000, calendar.date(2026, 6, 3, 12)),
      expense(100_000, calendar.date(2026, 6, 10, 12)),
    ]
    container = try RunwayModelContainer.make(inMemory: true)
  }

  func makeBudget(in context: ModelContext) throws -> Budget {
    let budget = Budget(
      periodLength: .weekly,
      periodStart: calendar.date(2026, 6, 1),
      spendablePerPeriodCents: 70_000
    )
    context.insert(budget)
    try context.save()
    return budget
  }

  func allowance(_ budget: Budget, now: Date) -> AllowanceResult {
    engine.currentAllowance(budget: BudgetSnapshot(budget), expenses: expenses, now: now)
  }

  @Test("A default-constructed budget maps to a snapshot with carryover on")
  func defaultSnapshot() {
    let budget = Budget(periodStart: calendar.date(2026, 6, 1), spendablePerPeriodCents: 70_000)
    let snapshot = BudgetSnapshot(budget)
    #expect(snapshot.carryoverEnabled)
    #expect(snapshot.carryoverChanges.isEmpty)
  }

  @Test("Turning carryover off mid-period keeps this period's carry-in and zeroes the next")
  func turnOffMidPeriod() throws {
    let context = ModelContext(container)
    let budget = try makeBudget(in: context)
    let toggledAt = calendar.date(2026, 6, 10, 12)
    #expect(allowance(budget, now: toggledAt).carryInCents == 20_000)

    budget.setCarryover(false, now: toggledAt, calendar: calendar)
    try context.save()

    #expect(!budget.carryoverEnabled)
    let changes = try context.fetch(FetchDescriptor<CarryoverChange>())
    #expect(changes.count == 1)
    let change = try #require(changes.first)
    #expect(!change.enabled)
    #expect(change.previousEnabled)
    #expect(change.effectiveAt == calendar.date(2026, 6, 15))
    #expect(change.budget?.persistentModelID == budget.persistentModelID)

    // 3 days left (Jun 12–14): (700 + 200 - 1_000) / 3 = -33.33…, floored to -33.34.
    let sameDay = allowance(budget, now: toggledAt)
    #expect(sameDay.carryInCents == 20_000)
    let laterThisPeriod = allowance(budget, now: calendar.date(2026, 6, 12, 9))
    #expect(laterThisPeriod.carryInCents == 20_000)
    #expect(laterThisPeriod.allowanceTodayCents == -3_334)

    let nextPeriod = allowance(budget, now: calendar.date(2026, 6, 15, 9))
    #expect(nextPeriod.carryInCents == 0)
    #expect(nextPeriod.allowanceTodayCents == 10_000)
  }

  @Test("Switching back before the boundary cancels the pending change")
  func switchBackBeforeBoundary() throws {
    let context = ModelContext(container)
    let budget = try makeBudget(in: context)

    budget.setCarryover(true, now: calendar.date(2026, 6, 9, 12), calendar: calendar)
    budget.setCarryover(false, now: calendar.date(2026, 6, 10, 12), calendar: calendar)
    budget.setCarryover(true, now: calendar.date(2026, 6, 12, 12), calendar: calendar)
    try context.save()

    #expect(budget.carryoverEnabled)
    #expect(budget.carryoverChanges.isEmpty)
    #expect(try context.fetchCount(FetchDescriptor<CarryoverChange>()) == 0)
    // 700 + 200 - 1_000 = -100 carried in.
    #expect(allowance(budget, now: calendar.date(2026, 6, 15, 9)).carryInCents == -10_000)
  }

  @Test("Changes in different periods each apply from their own boundary")
  func changesAcrossPeriods() throws {
    let context = ModelContext(container)
    let budget = try makeBudget(in: context)

    budget.setCarryover(false, now: calendar.date(2026, 6, 10, 12), calendar: calendar)
    budget.setCarryover(true, now: calendar.date(2026, 6, 17, 12), calendar: calendar)
    try context.save()

    #expect(budget.carryoverEnabled)
    #expect(
      BudgetSnapshot(budget).carryoverChanges == [
        CarryoverChangeSnapshot(
          enabled: false,
          previousEnabled: true,
          effectiveAt: calendar.date(2026, 6, 15)
        ),
        CarryoverChangeSnapshot(
          enabled: true,
          previousEnabled: false,
          effectiveAt: calendar.date(2026, 6, 22)
        ),
      ]
    )

    // Jun 8: on, +200. Jun 15: off, 0. Jun 22: on, and period 2 spent nothing: 700 + 0.
    let days = [
      calendar.date(2026, 6, 8, 9),
      calendar.date(2026, 6, 15, 9),
      calendar.date(2026, 6, 22, 9),
    ]
    #expect(days.map { allowance(budget, now: $0).carryInCents } == [20_000, 0, 70_000])
  }

  @Test("Setting the value already in effect records no change")
  func settingCurrentValue() throws {
    let context = ModelContext(container)
    let budget = try makeBudget(in: context)

    budget.setCarryover(true, now: calendar.date(2026, 6, 10, 12), calendar: calendar)
    try context.save()
    #expect(budget.carryoverEnabled)
    #expect(try context.fetchCount(FetchDescriptor<CarryoverChange>()) == 0)

    // Once "off" has applied, setting it again leaves the history alone.
    budget.setCarryover(false, now: calendar.date(2026, 6, 10, 12), calendar: calendar)
    budget.setCarryover(false, now: calendar.date(2026, 6, 17, 12), calendar: calendar)
    try context.save()
    #expect(!budget.carryoverEnabled)
    #expect(
      BudgetSnapshot(budget).carryoverChanges == [
        CarryoverChangeSnapshot(
          enabled: false,
          previousEnabled: true,
          effectiveAt: calendar.date(2026, 6, 15)
        )
      ]
    )
  }

  @Test("Moving the payday moves a pending change to the new next boundary")
  func movePaydayMovesPendingChange() throws {
    let context = ModelContext(container)
    let budget = try makeBudget(in: context)
    let now = calendar.date(2026, 6, 10, 12)
    budget.setCarryover(false, now: now, calendar: calendar)

    // Wednesday paydays: periods start Jun 3, Jun 10, Jun 17.
    budget.updatePeriod(.weekly, start: calendar.date(2026, 6, 3), now: now, calendar: calendar)
    try context.save()

    #expect(budget.periodStart == calendar.date(2026, 6, 3))
    #expect(try context.fetchCount(FetchDescriptor<CarryoverChange>()) == 1)
    #expect(
      BudgetSnapshot(budget).carryoverChanges == [
        CarryoverChangeSnapshot(
          enabled: false,
          previousEnabled: true,
          effectiveAt: calendar.date(2026, 6, 17)
        )
      ]
    )
    // Jun 3–9 spent $500 of $700, carried into Jun 10. Off from Jun 17.
    #expect(allowance(budget, now: calendar.date(2026, 6, 12, 9)).carryInCents == 20_000)
    #expect(allowance(budget, now: calendar.date(2026, 6, 17, 9)).carryInCents == 0)
  }

  @Test("Changing the period length moves a pending change to the new next boundary")
  func changeLengthMovesPendingChange() throws {
    let context = ModelContext(container)
    let budget = try makeBudget(in: context)
    let now = calendar.date(2026, 6, 10, 12)
    budget.setCarryover(false, now: now, calendar: calendar)

    budget.updatePeriod(.monthly, start: calendar.date(2026, 6, 1), now: now, calendar: calendar)
    try context.save()

    #expect(budget.periodLength == .monthly)
    #expect(budget.carryoverChanges.map(\.effectiveAt) == [calendar.date(2026, 7, 1)])
    #expect(try context.fetchCount(FetchDescriptor<CarryoverChange>()) == 1)
  }

  @Test("A period change drops pending changes that end up matching the setting in effect")
  func periodChangeDropsRedundantChanges() throws {
    let context = ModelContext(container)
    let budget = try makeBudget(in: context)
    budget.setCarryover(false, now: calendar.date(2026, 6, 10, 12), calendar: calendar)
    let now = calendar.date(2026, 6, 17, 12)
    budget.setCarryover(true, now: now, calendar: calendar)
    #expect(budget.carryoverChanges.count == 2)

    // Friday paydays starting Jun 12: the current period is Jun 12–18, so neither the Jun 15
    // "off" nor the Jun 22 "on" has applied yet. Together they're a no-op.
    budget.updatePeriod(.weekly, start: calendar.date(2026, 6, 12), now: now, calendar: calendar)
    try context.save()

    #expect(budget.carryoverEnabled)
    #expect(budget.carryoverChanges.isEmpty)
    #expect(try context.fetchCount(FetchDescriptor<CarryoverChange>()) == 0)
  }

  @Test("A period change keeps changes that have already applied")
  func periodChangeKeepsAppliedChanges() throws {
    let context = ModelContext(container)
    let budget = try makeBudget(in: context)
    budget.setCarryover(false, now: calendar.date(2026, 6, 10, 12), calendar: calendar)
    let before = BudgetSnapshot(budget).carryoverChanges

    // Biweekly from Jun 1: Jun 17 is in Jun 15–28, so the Jun 15 change has applied.
    let now = calendar.date(2026, 6, 17, 12)
    budget.updatePeriod(.biweekly, start: calendar.date(2026, 6, 1), now: now, calendar: calendar)
    budget.updatePeriod(.biweekly, start: calendar.date(2026, 6, 1), now: now, calendar: calendar)
    try context.save()

    #expect(BudgetSnapshot(budget).carryoverChanges == before)
    #expect(try context.fetchCount(FetchDescriptor<CarryoverChange>()) == 1)
  }

  @Test("Deleting a budget deletes its carryover changes")
  func budgetDeleteCascades() throws {
    let context = ModelContext(container)
    let budget = try makeBudget(in: context)
    budget.setCarryover(false, now: calendar.date(2026, 6, 10, 12), calendar: calendar)
    budget.setCarryover(true, now: calendar.date(2026, 6, 17, 12), calendar: calendar)
    try context.save()
    #expect(try context.fetchCount(FetchDescriptor<CarryoverChange>()) == 2)

    context.delete(budget)
    try context.save()

    #expect(try context.fetchCount(FetchDescriptor<Budget>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<CarryoverChange>()) == 0)
  }
}
