import Foundation
import Testing

@testable import Runway

/// Weekly $700 budget anchored Monday 2026-06-01 in Chicago.
/// Period 0 (Jun 1–7) spends $500, leaving +$200. Period 1 (Jun 8–14) spends $1,000.
struct AllowanceCarryoverTests {
  let calendar = Calendar.gregorian("America/Chicago")
  let engine: AllowanceEngine
  let expenses: [ExpenseSnapshot]

  init() {
    engine = AllowanceEngine(calendar: calendar)
    expenses = [
      expense(50_000, calendar.date(2026, 6, 3, 12)),
      expense(100_000, calendar.date(2026, 6, 10, 12)),
    ]
  }

  func makeBudget(
    carryoverEnabled: Bool,
    changes: [CarryoverChangeSnapshot] = []
  ) -> BudgetSnapshot {
    BudgetSnapshot(
      periodLength: .weekly,
      periodStart: calendar.date(2026, 6, 1),
      spendablePerPeriodCents: 70_000,
      carryoverEnabled: carryoverEnabled,
      carryoverChanges: changes
    )
  }

  /// A change that flips the setting unless `previousEnabled` says otherwise.
  func change(
    _ enabled: Bool,
    previousEnabled: Bool? = nil,
    effectiveAt: Date
  ) -> CarryoverChangeSnapshot {
    CarryoverChangeSnapshot(
      enabled: enabled,
      previousEnabled: previousEnabled ?? !enabled,
      effectiveAt: effectiveAt
    )
  }

  @Test("Carry-out of a completed period is spendable + carry-in - spent, and can be negative")
  func carryOut() {
    let budget = makeBudget(carryoverEnabled: true)
    let first = engine.carryOutCents(
      of: engine.period(at: 0, of: budget),
      budget: budget,
      expenses: expenses,
      carryInCents: 0
    )
    #expect(first == 20_000)

    let second = engine.carryOutCents(
      of: engine.period(at: 1, of: budget),
      budget: budget,
      expenses: expenses,
      carryInCents: first
    )
    #expect(second == -10_000)
  }

  @Test("With carryover on, leftovers and overspending chain into later periods")
  func carryoverOn() {
    let budget = makeBudget(carryoverEnabled: true)

    // (700 + 200) / 7 = 128.571…, floored.
    let secondPeriod = engine.currentAllowance(
      budget: budget,
      expenses: expenses,
      now: calendar.date(2026, 6, 8, 10)
    )
    #expect(secondPeriod.period.index == 1)
    #expect(secondPeriod.carryInCents == 20_000)
    #expect(secondPeriod.allowanceTodayCents == 12_857)
    #expect(secondPeriod.remainingPeriodCents == 90_000)

    // 700 + 200 - 1_000 = -100 carried in: (700 - 100) / 7 = 85.714…, floored.
    let thirdPeriod = engine.currentAllowance(
      budget: budget,
      expenses: expenses,
      now: calendar.date(2026, 6, 15, 9)
    )
    #expect(thirdPeriod.period.index == 2)
    #expect(thirdPeriod.carryInCents == -10_000)
    #expect(thirdPeriod.allowanceTodayCents == 8_571)
    #expect(thirdPeriod.remainingPeriodCents == 60_000)
    #expect(!thirdPeriod.isOverBudget)
  }

  @Test("With carryover off, every period starts fresh")
  func carryoverOff() {
    let budget = makeBudget(carryoverEnabled: false)
    for now in [calendar.date(2026, 6, 8, 10), calendar.date(2026, 6, 15, 9)] {
      let result = engine.currentAllowance(budget: budget, expenses: expenses, now: now)
      #expect(result.carryInCents == 0)
      #expect(result.allowanceTodayCents == 10_000)
      #expect(result.remainingPeriodCents == 70_000)
    }
  }

  @Test("Turning carryover off mid-period keeps this period's carry-in and zeroes the next")
  func toggledOffMidPeriod() {
    // The setting is now off; boundaries before the change use its previous value (on).
    let budget = makeBudget(
      carryoverEnabled: false,
      changes: [change(false, effectiveAt: calendar.date(2026, 6, 15))]
    )

    #expect(engine.isCarryoverEnabled(atBoundary: calendar.date(2026, 6, 8), budget: budget))
    #expect(!engine.isCarryoverEnabled(atBoundary: calendar.date(2026, 6, 15), budget: budget))

    // 3 days left (Jun 12–14): (700 + 200 - 1_000) / 3 = -33.33…, floored to -33.34.
    let afterToggle = engine.currentAllowance(
      budget: budget,
      expenses: expenses,
      now: calendar.date(2026, 6, 12, 9)
    )
    #expect(afterToggle.carryInCents == 20_000)
    #expect(afterToggle.daysLeft == 3)
    #expect(afterToggle.allowanceTodayCents == -3_334)
    #expect(afterToggle.remainingPeriodCents == -10_000)
    #expect(afterToggle.isOverBudget)

    let nextPeriod = engine.currentAllowance(
      budget: budget,
      expenses: expenses,
      now: calendar.date(2026, 6, 15, 9)
    )
    #expect(nextPeriod.carryInCents == 0)
    #expect(nextPeriod.allowanceTodayCents == 10_000)
  }

  @Test("Turning carryover on mid-period first carries this period's result into the next")
  func toggledOnMidPeriod() {
    // A mid-period `effectiveAt` applies from the next boundary (Jun 15).
    let budget = makeBudget(
      carryoverEnabled: true,
      changes: [change(true, effectiveAt: calendar.date(2026, 6, 10, 12))]
    )

    // (700 - 1_000) / 3 = -100.
    let afterToggle = engine.currentAllowance(
      budget: budget,
      expenses: expenses,
      now: calendar.date(2026, 6, 12, 9)
    )
    #expect(afterToggle.carryInCents == 0)
    #expect(afterToggle.allowanceTodayCents == -10_000)

    // Period 1 started fresh, so it carries 700 - 1_000 = -300: (700 - 300) / 7 = 57.142…
    let nextPeriod = engine.currentAllowance(
      budget: budget,
      expenses: expenses,
      now: calendar.date(2026, 6, 15, 9)
    )
    #expect(nextPeriod.carryInCents == -30_000)
    #expect(nextPeriod.allowanceTodayCents == 5_714)
    #expect(nextPeriod.remainingPeriodCents == 40_000)
  }

  @Test("A change effective exactly at a boundary applies from that boundary")
  func toggledAtBoundary() {
    let atBoundary = makeBudget(
      carryoverEnabled: false,
      changes: [change(false, effectiveAt: calendar.date(2026, 6, 15))]
    )
    let result = engine.currentAllowance(
      budget: atBoundary,
      expenses: expenses,
      now: calendar.date(2026, 6, 15, 9)
    )
    #expect(result.carryInCents == 0)
    #expect(result.allowanceTodayCents == 10_000)

    // One second later, it waits for the following boundary. Period 2 carries in -100 and
    // spends nothing, so it would carry out 600 if carryover were still on.
    let justAfter = makeBudget(
      carryoverEnabled: false,
      changes: [change(false, effectiveAt: calendar.date(2026, 6, 15, 0, 0, 1))]
    )
    let sameDay = engine.currentAllowance(
      budget: justAfter,
      expenses: expenses,
      now: calendar.date(2026, 6, 15, 9)
    )
    #expect(sameDay.carryInCents == -10_000)

    let following = engine.currentAllowance(
      budget: justAfter,
      expenses: expenses,
      now: calendar.date(2026, 6, 22, 9)
    )
    #expect(following.carryInCents == 0)
    #expect(following.allowanceTodayCents == 10_000)
  }

  @Test("Boundaries before the first change use its recorded previous value, not its opposite")
  func previousEnabledBeforeFirstChange() {
    // Neither change flips the setting, so assuming "the opposite" would get Jun 8 wrong.
    let stayedOn = makeBudget(
      carryoverEnabled: true,
      changes: [change(true, previousEnabled: true, effectiveAt: calendar.date(2026, 6, 15))]
    )
    #expect(engine.isCarryoverEnabled(atBoundary: calendar.date(2026, 6, 8), budget: stayedOn))
    let carryIn = engine.currentAllowance(
      budget: stayedOn,
      expenses: expenses,
      now: calendar.date(2026, 6, 8, 9)
    )
    #expect(carryIn.carryInCents == 20_000)

    let stayedOff = makeBudget(
      carryoverEnabled: false,
      changes: [change(false, previousEnabled: false, effectiveAt: calendar.date(2026, 6, 15))]
    )
    #expect(!engine.isCarryoverEnabled(atBoundary: calendar.date(2026, 6, 8), budget: stayedOff))
    let noCarryIn = engine.currentAllowance(
      budget: stayedOff,
      expenses: expenses,
      now: calendar.date(2026, 6, 8, 9)
    )
    #expect(noCarryIn.carryInCents == 0)
  }

  @Test("Each change applies from its own boundary; before the first, its previous value applies")
  func severalChanges() {
    let budget = makeBudget(
      carryoverEnabled: true,
      changes: [
        change(false, effectiveAt: calendar.date(2026, 6, 15)),
        change(true, effectiveAt: calendar.date(2026, 6, 22)),
      ]
    )
    let days = [
      calendar.date(2026, 6, 8, 9),
      calendar.date(2026, 6, 15, 9),
      calendar.date(2026, 6, 22, 9),
    ]
    let carryIns = days.map { now in
      engine.currentAllowance(budget: budget, expenses: expenses, now: now).carryInCents
    }
    // Jun 8: on, +200. Jun 15: off, 0. Jun 22: on, and period 2 spent nothing: 700 + 0.
    #expect(carryIns == [20_000, 0, 70_000])
  }
}
