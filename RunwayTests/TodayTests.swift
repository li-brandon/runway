import Foundation
import SwiftData
import Testing

@testable import Runway

struct TodayTests {
  let calendar = Calendar.gregorian("America/Chicago")

  @Test("Daily status handles the strict threshold, zero, and negative allowances")
  func statusEdges() {
    let cases: [(Int, Int, TodayStatus)] = [
      (100, 21, .normal),
      (100, 20, .normal),
      (100, 19, .nearLimit),
      (100, 0, .nearLimit),
      (100, -1, .over),
      (0, 0, .noAllowance),
      (0, -1, .over),
      (0, 1, .noAllowance),
      (-100, -100, .over),
      (-100, 0, .noAllowance),
      (-100, 1, .noAllowance),
      (1, 0, .nearLimit),
      (Int.max, Int.max, .normal),
    ]
    for (allowance, remaining, expected) in cases {
      let day = calendar.date(2026, 6, 10)
      let result = AllowanceResult(
        period: BudgetPeriod(index: 0, start: day, end: calendar.date(2026, 6, 11)),
        carryInCents: 0,
        allowanceTodayCents: allowance,
        spentTodayCents: 0,
        remainingTodayCents: remaining,
        remainingPeriodCents: 100,
        daysLeft: 1,
        isOverBudget: remaining < 0
      )
      #expect(TodayStatus(result) == expected)
      #expect(!expected.title.isEmpty)
      #expect(!expected.symbol.isEmpty)
    }
  }

  @Test("Midnight follows calendar boundaries on ordinary, 23-hour, and 25-hour days")
  func midnight() {
    for (month, day, hours) in [(6, 10, 24), (3, 8, 23), (11, 1, 25)] {
      let start = calendar.date(2026, month, day)
      let expected = calendar.date(2026, month, day + 1)
      #expect(nextMidnight(after: start, calendar: calendar) == expected)
      #expect(expected.timeIntervalSince(start) == Double(hours * 3_600))
      let evening = calendar.date(2026, month, day, 23, 59, 59)
      #expect(nextMidnight(after: evening, calendar: calendar) == expected)
      let following = calendar.date(byAdding: .day, value: 1, to: expected)!
      #expect(nextMidnight(after: expected, calendar: calendar) == following)
    }
  }

  @Test("Screenshot seeds produce the requested daily states and show categorized refunds")
  func screenshotStates() throws {
    let now = calendar.date(2026, 6, 10, 12)
    let cases: [(ScreenshotScenario, TodayStatus, Int)] = [
      (.todayNormal, .normal, 8_000),
      (.todayNear, .nearLimit, 1_000),
      (.todayOver, .over, -2_000),
    ]
    for (scenario, status, remaining) in cases {
      let container = try RunwayModelContainer.make(inMemory: true)
      let context = ModelContext(container)
      let budget = try #require(try scenario.seed(into: context, now: now, calendar: calendar))
      let expenses = try context.fetch(FetchDescriptor<Expense>())
      let result = AllowanceEngine(calendar: calendar).currentAllowance(
        budget: BudgetSnapshot(budget),
        expenses: expenses.map { ExpenseSnapshot($0) },
        now: now
      )
      #expect(TodayStatus(result) == status)
      #expect(result.remainingTodayCents == remaining)
      #expect(expenses.count == 2)
      #expect(expenses.contains { $0.amountCents == -500 })
      #expect(expenses.allSatisfy { $0.category != nil })
    }
  }

  @Test("Zero allowance screenshots show no allowance left with nothing spent")
  func zeroAllowanceScreenshot() throws {
    let now = calendar.date(2026, 6, 10, 12)
    let container = try RunwayModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    let budget = try #require(
      try ScreenshotScenario.todayZero.seed(into: context, now: now, calendar: calendar)
    )
    let expenses = try context.fetch(FetchDescriptor<Expense>())
    let result = AllowanceEngine(calendar: calendar).currentAllowance(
      budget: BudgetSnapshot(budget),
      expenses: expenses.map { ExpenseSnapshot($0) },
      now: now
    )
    #expect(expenses.isEmpty)
    #expect(result.allowanceTodayCents == 0)
    #expect(result.spentTodayCents == 0)
    #expect(result.remainingTodayCents == 0)
    #expect(TodayStatus(result) == .noAllowance)
    #expect(TodayStatus(result).title == "No allowance left")
    #expect(TodayStatus(result).symbol != TodayStatus.normal.symbol)
  }

  @Test("Today excludes adjacent days and orders by spending date then logging time")
  func expenseOrdering() {
    let now = calendar.date(2026, 6, 10, 12)
    let morning = calendar.date(2026, 6, 10, 8)
    let first = makeFixtureExpense(amountCents: 100, date: morning, createdAt: morning)
    let second = makeFixtureExpense(amountCents: 200, date: morning, createdAt: now)
    let refund = makeFixtureExpense(amountCents: -50, date: now, createdAt: morning)
    let yesterday = makeFixtureExpense(amountCents: 300, date: calendar.date(2026, 6, 9, 23, 59))
    let tomorrow = makeFixtureExpense(amountCents: 400, date: calendar.date(2026, 6, 11))
    let all = [tomorrow, first, yesterday, second, refund]
    let today = todayExpenses(all, now: now, calendar: calendar)
    #expect(today.map(\.amountCents) == [-50, 200, 100])
    let midnight = nextMidnight(after: now, calendar: calendar)
    let nextDay = todayExpenses(all, now: midnight, calendar: calendar)
    #expect(nextDay.map(\.amountCents) == [400])
  }

}
