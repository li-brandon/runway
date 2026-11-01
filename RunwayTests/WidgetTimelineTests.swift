import Combine
import Foundation
import SwiftData
import Testing
import UIKit

@testable import Runway

struct WidgetTimelinePlannerTests {
  private let calendar = Calendar.gregorian("America/Chicago")
  private let hour: TimeInterval = 60 * 60

  private var planner: WidgetTimelinePlanner {
    WidgetTimelinePlanner(calendar: calendar)
  }

  private func budget(from start: Date) -> BudgetSnapshot {
    BudgetSnapshot(periodLength: .biweekly, periodStart: start, spendablePerPeriodCents: 140_000)
  }

  private func allowances(in plan: WidgetTimelinePlan) -> [WidgetAllowance] {
    plan.entries.compactMap { entry in
      guard case .allowance(let allowance) = entry.content else { return nil }
      return allowance
    }
  }

  private func plan(
    from start: Date,
    expenses: [ExpenseSnapshot] = [],
    now: Date
  ) -> WidgetTimelinePlan {
    planner.plan(
      budget: budget(from: start),
      expenses: expenses,
      amountsArePrivate: false,
      now: now
    )
  }

  // MARK: - DST

  @Test("The 25-hour day ends at the real midnight, even in the repeated hour")
  func fallBack() {
    let start = calendar.date(2026, 11, 1)
    let midnight = calendar.date(2026, 11, 2)
    #expect(midnight.timeIntervalSince(start) == 25 * hour)

    // 2.5 hours after midnight is the second 1:30 AM.
    for now in [start, start.addingTimeInterval(2.5 * hour), calendar.date(2026, 11, 1, 12)] {
      let result = plan(from: calendar.date(2026, 10, 18), now: now)
      let dates = result.entries.map { $0.date }
      #expect(dates == [now, midnight])
      #expect(result.reloadDate == midnight)
    }
  }

  @Test("The 23-hour day ends at the real midnight, on either side of the skipped hour")
  func springForward() {
    let start = calendar.date(2026, 3, 8)
    let midnight = calendar.date(2026, 3, 9)
    #expect(midnight.timeIntervalSince(start) == 23 * hour)

    for now in [start, calendar.date(2026, 3, 8, 1, 30), calendar.date(2026, 3, 8, 3, 30)] {
      let result = plan(from: calendar.date(2026, 3, 1), now: now)
      let dates = result.entries.map { $0.date }
      #expect(dates == [now, midnight])
      #expect(result.reloadDate == midnight)
    }
  }

  @Test("The day before each change rolls over at the change day's midnight")
  func dayBeforeChange() {
    let fall = plan(from: calendar.date(2026, 10, 18), now: calendar.date(2026, 10, 31, 12))
    #expect(fall.reloadDate == calendar.date(2026, 11, 1))
    let spring = plan(from: calendar.date(2026, 3, 1), now: calendar.date(2026, 3, 7, 12))
    #expect(spring.reloadDate == calendar.date(2026, 3, 8))
  }

  @Test("Days left drops by exactly one across a DST day")
  func daysLeftAcrossChange() {
    let fall = plan(from: calendar.date(2026, 11, 1), now: calendar.date(2026, 11, 1, 12))
    let fallDays = allowances(in: fall).map { $0.daysLeft }
    #expect(fallDays == [14, 13])

    let spring = plan(from: calendar.date(2026, 3, 1), now: calendar.date(2026, 3, 8, 12))
    let springDays = allowances(in: spring).map { $0.daysLeft }
    #expect(springDays == [7, 6])
  }

  // MARK: - Period boundaries

  @Test("The last day's midnight entry is already in the new period")
  func periodBoundary() {
    let now = calendar.date(2026, 6, 14, 12)
    let boundary = calendar.date(2026, 6, 15)
    let result = plan(from: calendar.date(2026, 6, 1), now: now)

    let dates = result.entries.map { $0.date }
    #expect(dates == [now, boundary])
    #expect(result.reloadDate == boundary)
    let days = allowances(in: result).map { $0.daysLeft }
    #expect(days == [1, 14])
  }

  @Test("A period boundary on a DST day is the same local midnight")
  func periodBoundaryOnChange() {
    let now = calendar.date(2026, 10, 31, 12)
    let boundary = calendar.date(2026, 11, 1)
    let result = plan(from: calendar.date(2026, 10, 18), now: now)

    let dates = result.entries.map { $0.date }
    #expect(dates == [now, boundary])
    let days = allowances(in: result).map { $0.daysLeft }
    #expect(days == [1, 14])
  }

  @Test("A period start or end before midnight gets its own entry, oldest first")
  func boundariesBeforeMidnight() {
    let now = calendar.date(2026, 6, 10, 12)
    let start = calendar.date(2026, 6, 10, 15)
    let end = calendar.date(2026, 6, 10, 18)
    let period = BudgetPeriod(index: 0, start: start, end: end)
    let dates = planner.entryDates(now: now, period: period)
    #expect(dates == [now, start, end, calendar.date(2026, 6, 11)])
  }

  @Test("A boundary at now, at midnight, or past either adds nothing")
  func boundariesOutsideTheDay() {
    let now = calendar.date(2026, 6, 10)
    let midnight = calendar.date(2026, 6, 11)
    let atBoth = BudgetPeriod(index: 0, start: now, end: midnight)
    let atBothDates = planner.entryDates(now: now, period: atBoth)
    #expect(atBothDates == [now, midnight])

    let wider = BudgetPeriod(
      index: 0,
      start: calendar.date(2026, 6, 1),
      end: calendar.date(2026, 6, 15)
    )
    let widerDates = planner.entryDates(now: now, period: wider)
    #expect(widerDates == [now, midnight])
  }

  // MARK: - Figures

  @Test("The midnight entry already has the new day's number")
  func rollover() {
    let now = calendar.date(2026, 6, 10, 12)
    let result = plan(from: calendar.date(2026, 6, 1), expenses: [expense(2_500, now)], now: now)

    // $1,400 over 5 days less the $25 spent, then the $1,375 left over the 4 days after.
    let figures = allowances(in: result)
    let today = figures.map { $0.remainingTodayCents }
    #expect(today == [25_500, 34_375])
    let days = figures.map { $0.daysLeft }
    #expect(days == [5, 4])
  }

  @Test("Every entry carries the app lock setting")
  func privacy() {
    let result = planner.plan(
      budget: budget(from: calendar.date(2026, 6, 1)),
      expenses: [],
      amountsArePrivate: true,
      now: calendar.date(2026, 6, 10, 12)
    )
    let flags = result.entries.map { $0.amountsArePrivate }
    #expect(flags == [true, true])
  }
}

@MainActor
struct WidgetReloaderTests {
  @Test("Saves, clock changes, and time zone changes each fire once; other notifications don't")
  func triggers() {
    let center = NotificationCenter()
    var count = 0
    let subscription = WidgetReloader.triggers(in: center).sink { _ in count += 1 }
    defer { subscription.cancel() }

    center.post(name: Notification.Name("unrelated"), object: nil)
    #expect(count == 0)
    center.post(name: ModelContext.didSave, object: nil)
    #expect(count == 1)
    center.post(name: UIApplication.significantTimeChangeNotification, object: nil)
    #expect(count == 2)
    center.post(name: NSNotification.Name.NSSystemTimeZoneDidChange, object: nil)
    #expect(count == 3)
  }
}
