import Foundation
import Testing

@testable import Runway

/// Core allowance math. Weekly $700 budget anchored Monday 2026-06-01 in Chicago (no DST changes
/// that week), so an even split is $100 a day.
struct AllowanceEngineTests {
  let calendar = Calendar.gregorian("America/Chicago")
  let engine: AllowanceEngine
  let budget: BudgetSnapshot

  init() {
    engine = AllowanceEngine(calendar: calendar)
    budget = BudgetSnapshot(
      periodLength: .weekly,
      periodStart: calendar.date(2026, 6, 1),
      spendablePerPeriodCents: 70_000
    )
  }

  @Test("First day splits the period evenly; today's spending doesn't change today's allowance")
  func firstDay() {
    let result = engine.allowance(
      budget: budget,
      expenses: [expense(2_500, calendar.date(2026, 6, 1, 8))],
      carryInCents: 0,
      now: calendar.date(2026, 6, 1, 9)
    )
    #expect(result.period.index == 0)
    #expect(result.periodStart == calendar.date(2026, 6, 1))
    #expect(result.periodEnd == calendar.date(2026, 6, 8))
    #expect(result.carryInCents == 0)
    #expect(result.daysLeft == 7)
    #expect(result.allowanceTodayCents == 10_000)
    #expect(result.spentTodayCents == 2_500)
    #expect(result.remainingTodayCents == 7_500)
    #expect(result.remainingPeriodCents == 67_500)
    #expect(!result.isOverBudget)
  }

  @Test("Last day gets everything that's left")
  func lastDay() {
    let result = engine.allowance(
      budget: budget,
      expenses: [
        expense(50_000, calendar.date(2026, 6, 1, 10)),
        expense(4_000, calendar.date(2026, 6, 7, 12)),
      ],
      carryInCents: 0,
      now: calendar.date(2026, 6, 7, 20)
    )
    #expect(result.daysLeft == 1)
    #expect(result.allowanceTodayCents == 20_000)
    #expect(result.spentTodayCents == 4_000)
    #expect(result.remainingTodayCents == 16_000)
    #expect(result.remainingPeriodCents == 16_000)
    #expect(!result.isOverBudget)
  }

  @Test("Underspending raises later days' allowance")
  func underspend() {
    // Spent $40 of $100 on day 1: (700 - 40) / 6 = 110.
    let result = engine.allowance(
      budget: budget,
      expenses: [expense(4_000, calendar.date(2026, 6, 1, 12))],
      carryInCents: 0,
      now: calendar.date(2026, 6, 2, 9)
    )
    #expect(result.daysLeft == 6)
    #expect(result.allowanceTodayCents == 11_000)
    #expect(result.spentTodayCents == 0)
    #expect(result.remainingTodayCents == 11_000)
    #expect(result.remainingPeriodCents == 66_000)
    #expect(!result.isOverBudget)
  }

  @Test("Overspending goes negative today and lowers later days' allowance")
  func overspend() {
    let expenses = [expense(16_000, calendar.date(2026, 6, 1, 12))]

    let dayOne = engine.allowance(
      budget: budget,
      expenses: expenses,
      carryInCents: 0,
      now: calendar.date(2026, 6, 1, 18)
    )
    #expect(dayOne.allowanceTodayCents == 10_000)
    #expect(dayOne.spentTodayCents == 16_000)
    #expect(dayOne.remainingTodayCents == -6_000)
    #expect(dayOne.remainingPeriodCents == 54_000)
    #expect(dayOne.isOverBudget)

    // (700 - 160) / 6 = 90.
    let dayTwo = engine.allowance(
      budget: budget,
      expenses: expenses,
      carryInCents: 0,
      now: calendar.date(2026, 6, 2, 9)
    )
    #expect(dayTwo.allowanceTodayCents == 9_000)
    #expect(dayTwo.remainingTodayCents == 9_000)
    #expect(dayTwo.remainingPeriodCents == 54_000)
    #expect(!dayTwo.isOverBudget)
  }

  @Test("An overspent period gives a negative allowance, rounded down")
  func overspentPeriod() {
    // -5_001 / 5 = -1_000.2, floored to -1_001 (truncation would overstate it as -1_000).
    let result = engine.allowance(
      budget: budget,
      expenses: [expense(75_001, calendar.date(2026, 6, 1, 12))],
      carryInCents: 0,
      now: calendar.date(2026, 6, 3, 9)
    )
    #expect(result.daysLeft == 5)
    #expect(result.allowanceTodayCents == -1_001)
    #expect(result.spentTodayCents == 0)
    #expect(result.remainingTodayCents == -1_001)
    #expect(result.remainingPeriodCents == -5_001)
    #expect(result.isOverBudget)
  }

  @Test("Floor division rounds toward negative infinity")
  func floorDivision() {
    #expect(AllowanceEngine.floorDivide(70_000, by: 6) == 11_666)
    #expect(AllowanceEngine.floorDivide(7, by: 2) == 3)
    #expect(AllowanceEngine.floorDivide(6, by: 3) == 2)
    #expect(AllowanceEngine.floorDivide(0, by: 5) == 0)
    #expect(AllowanceEngine.floorDivide(-6, by: 3) == -2)
    #expect(AllowanceEngine.floorDivide(-7, by: 2) == -4)
    #expect(AllowanceEngine.floorDivide(-1, by: 7) == -1)
  }

  @Test("Negative carry-in reduces the period")
  func negativeCarryIn() {
    let reduced = engine.allowance(
      budget: budget,
      expenses: [],
      carryInCents: -14_000,
      now: calendar.date(2026, 6, 1, 9)
    )
    #expect(reduced.carryInCents == -14_000)
    #expect(reduced.allowanceTodayCents == 8_000)
    #expect(reduced.remainingPeriodCents == 56_000)
    #expect(!reduced.isOverBudget)

    // -10_000 / 7 = -1_428.57…, floored to -1_429.
    let underwater = engine.allowance(
      budget: budget,
      expenses: [],
      carryInCents: -80_000,
      now: calendar.date(2026, 6, 1, 9)
    )
    #expect(underwater.allowanceTodayCents == -1_429)
    #expect(underwater.remainingTodayCents == -1_429)
    #expect(underwater.remainingPeriodCents == -10_000)
    #expect(underwater.isOverBudget)
  }

  @Test("After the period ends there are zero days left and no divide-by-zero")
  func zeroDaysLeft() {
    let period = engine.period(at: 0, of: budget)
    let expenses = [
      expense(30_000, calendar.date(2026, 6, 1, 12)),
      expense(5_000, calendar.date(2026, 6, 9, 12)),  // Next period: ignored.
    ]

    let afterEnd = engine.allowance(
      in: period,
      budget: budget,
      expenses: expenses,
      carryInCents: 0,
      now: calendar.date(2026, 6, 10, 12)
    )
    #expect(afterEnd.daysLeft == 0)
    #expect(afterEnd.allowanceTodayCents == 40_000)
    #expect(afterEnd.spentTodayCents == 0)
    #expect(afterEnd.remainingTodayCents == 40_000)
    #expect(afterEnd.remainingPeriodCents == 40_000)
    #expect(!afterEnd.isOverBudget)

    let atEnd = engine.allowance(
      in: period,
      budget: budget,
      expenses: [expense(80_000, calendar.date(2026, 6, 7, 12))],
      carryInCents: 0,
      now: period.end
    )
    #expect(atEnd.daysLeft == 0)
    #expect(atEnd.allowanceTodayCents == -10_000)
    #expect(atEnd.spentTodayCents == 0)
    #expect(atEnd.remainingPeriodCents == -10_000)
    #expect(atEnd.isOverBudget)
  }

  @Test("Before the anchor, the first period's first day is previewed")
  func beforeAnchor() {
    let result = engine.currentAllowance(
      budget: budget,
      expenses: [expense(5_000, calendar.date(2026, 5, 31, 12))],
      now: calendar.date(2026, 5, 30, 12)
    )
    #expect(result.period.index == 0)
    #expect(result.periodStart == calendar.date(2026, 6, 1))
    #expect(result.daysLeft == 7)
    #expect(result.allowanceTodayCents == 10_000)
    #expect(result.spentTodayCents == 0)
    #expect(result.remainingPeriodCents == 70_000)
  }

  @Test("Expenses at 23:59:59 belong to that day and at 00:00 to the next")
  func midnightBoundary() {
    let expenses = [
      expense(1_000, calendar.date(2026, 6, 2, 23, 59, 59)),
      expense(2_000, calendar.date(2026, 6, 3)),
    ]

    // The 2026-06-03 expense hasn't happened yet, so it's ignored.
    let lateEvening = engine.allowance(
      budget: budget,
      expenses: expenses,
      carryInCents: 0,
      now: calendar.date(2026, 6, 2, 23, 59, 59)
    )
    #expect(lateEvening.daysLeft == 6)
    #expect(lateEvening.allowanceTodayCents == 11_666)
    #expect(lateEvening.spentTodayCents == 1_000)
    #expect(lateEvening.remainingTodayCents == 10_666)
    #expect(lateEvening.remainingPeriodCents == 69_000)

    // (700 - 10) / 5 = 138.
    let midnight = engine.allowance(
      budget: budget,
      expenses: expenses,
      carryInCents: 0,
      now: calendar.date(2026, 6, 3)
    )
    #expect(midnight.daysLeft == 5)
    #expect(midnight.allowanceTodayCents == 13_800)
    #expect(midnight.spentTodayCents == 2_000)
    #expect(midnight.remainingTodayCents == 11_800)
    #expect(midnight.remainingPeriodCents == 67_000)
  }

  @Test("Expenses outside the period are ignored")
  func expensesOutsidePeriod() {
    let expenses = [
      expense(9_000, calendar.date(2026, 5, 31, 23, 59, 59)),
      expense(3_000, calendar.date(2026, 6, 4, 12)),
      expense(9_000, calendar.date(2026, 6, 8)),
    ]
    let firstPeriod = engine.period(at: 0, of: budget)
    let carryOut = engine.carryOutCents(
      of: firstPeriod,
      budget: budget,
      expenses: expenses,
      carryInCents: 0
    )
    #expect(carryOut == 67_000)

    let lastDay = engine.allowance(
      budget: budget,
      expenses: expenses,
      carryInCents: 0,
      now: calendar.date(2026, 6, 7, 12)
    )
    #expect(lastDay.allowanceTodayCents == 67_000)
    #expect(lastDay.spentTodayCents == 0)

    let nextPeriod = engine.allowance(
      budget: budget,
      expenses: expenses,
      carryInCents: 0,
      now: calendar.date(2026, 6, 8, 12)
    )
    #expect(nextPeriod.period.index == 1)
    #expect(nextPeriod.allowanceTodayCents == 10_000)
    #expect(nextPeriod.spentTodayCents == 9_000)
    #expect(nextPeriod.remainingPeriodCents == 61_000)
  }

  @Test("Expenses dated before the budget's start are ignored, even in the preview and carryover")
  func expensesBeforeStart() {
    let expenses = [
      expense(9_000, calendar.date(2026, 5, 31, 12)),
      expense(3_000, calendar.date(2026, 6, 3, 12)),
    ]

    // Previewing period 0 later on the day of the early expense: nothing is spent yet.
    let preview = engine.currentAllowance(
      budget: budget,
      expenses: expenses,
      now: calendar.date(2026, 5, 31, 18)
    )
    #expect(preview.period.index == 0)
    #expect(preview.allowanceTodayCents == 10_000)
    #expect(preview.spentTodayCents == 0)
    #expect(preview.remainingPeriodCents == 70_000)

    // Jun 4–7 left: (700 - 30) / 4 = 167.50.
    let fourthDay = engine.currentAllowance(
      budget: budget,
      expenses: expenses,
      now: calendar.date(2026, 6, 4, 9)
    )
    #expect(fourthDay.daysLeft == 4)
    #expect(fourthDay.allowanceTodayCents == 16_750)
    #expect(fourthDay.remainingPeriodCents == 67_000)

    let nextPeriod = engine.currentAllowance(
      budget: budget,
      expenses: expenses,
      now: calendar.date(2026, 6, 8, 9)
    )
    #expect(nextPeriod.carryInCents == 67_000)
  }

  @Test("Carryover is on by default")
  func carryoverDefault() {
    #expect(budget.carryoverEnabled)
  }
}
