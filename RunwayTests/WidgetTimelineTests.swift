import Combine
import Foundation
import SwiftData
import Testing
import UIKit
import os

@testable import Runway

struct WidgetTimelinePlannerTests {
  private let calendar = Calendar.gregorian("America/Chicago")
  private let utc = Calendar.gregorian("UTC")
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
      #expect(result.reloadDate == now.addingTimeInterval(hour))
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
      #expect(result.reloadDate == now.addingTimeInterval(hour))
    }
  }

  @Test("The day before each change rolls over at the change day's midnight")
  func dayBeforeChange() {
    let fall = plan(from: calendar.date(2026, 10, 18), now: calendar.date(2026, 10, 31, 23, 30))
    #expect(fall.reloadDate == calendar.date(2026, 11, 1))
    let spring = plan(from: calendar.date(2026, 3, 1), now: calendar.date(2026, 3, 7, 23, 30))
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

  // MARK: - Reload date

  @Test("Reloads an hour from now when midnight is further away")
  func reloadWithinTheHour() {
    let now = calendar.date(2026, 6, 10, 12)
    let result = plan(from: calendar.date(2026, 6, 1), now: now)
    #expect(planner.reloadDate(now: now) == calendar.date(2026, 6, 10, 13))
    #expect(result.reloadDate == calendar.date(2026, 6, 10, 13))
    let dates = result.entries.map { $0.date }
    #expect(dates == [now, calendar.date(2026, 6, 11)])
  }

  @Test("Reloads at midnight when that's within the hour")
  func reloadAtMidnight() {
    let midnight = calendar.date(2026, 6, 11)
    for now in [calendar.date(2026, 6, 10, 23), calendar.date(2026, 6, 10, 23, 30)] {
      let result = plan(from: calendar.date(2026, 6, 1), now: now)
      #expect(result.reloadDate == midnight)
      let dates = result.entries.map { $0.date }
      #expect(dates == [now, midnight])
    }
  }

  @Test("On the 25-hour day, an hour is elapsed time, even in the repeated hour")
  func reloadOnFallBack() {
    let firstOneThirty = utc.date(2026, 11, 1, 6, 30)
    let secondOneThirty = utc.date(2026, 11, 1, 7, 30)
    let wallClockHours = [firstOneThirty, secondOneThirty].map {
      calendar.component(.hour, from: $0)
    }
    #expect(wallClockHours == [1, 1])

    let midnight = utc.date(2026, 11, 2, 6)
    let cases: [(now: Date, reload: Date)] = [
      (utc.date(2026, 11, 1, 5), utc.date(2026, 11, 1, 6)),
      (firstOneThirty, secondOneThirty),
      (secondOneThirty, utc.date(2026, 11, 1, 8, 30)),
      (utc.date(2026, 11, 2, 4, 59), utc.date(2026, 11, 2, 5, 59)),
      // 11:00 PM, where an hour from now and midnight are the same moment.
      (utc.date(2026, 11, 2, 5), midnight),
      // 11:30 PM.
      (utc.date(2026, 11, 2, 5, 30), midnight),
    ]
    for (now, reload) in cases {
      let result = plan(from: calendar.date(2026, 10, 18), now: now)
      #expect(result.reloadDate == reload)
      let dates = result.entries.map { $0.date }
      #expect(dates == [now, midnight])
    }
  }

  @Test("On the 23-hour day, an hour is elapsed time, even across the skipped hour")
  func reloadOnSpringForward() {
    // No moment falls inside the skipped hour, so these are the moments on either side of it.
    let beforeSkip = utc.date(2026, 3, 8, 7, 59)
    let afterSkip = utc.date(2026, 3, 8, 8)
    let wallClockHours = [beforeSkip, afterSkip].map { calendar.component(.hour, from: $0) }
    #expect(wallClockHours == [1, 3])

    let midnight = utc.date(2026, 3, 9, 5)
    let cases: [(now: Date, reload: Date)] = [
      (utc.date(2026, 3, 8, 7, 30), utc.date(2026, 3, 8, 8, 30)),
      (beforeSkip, utc.date(2026, 3, 8, 8, 59)),
      (afterSkip, utc.date(2026, 3, 8, 9)),
      (utc.date(2026, 3, 9, 3, 59), utc.date(2026, 3, 9, 4, 59)),
      // 11:00 PM, where an hour from now and midnight are the same moment.
      (utc.date(2026, 3, 9, 4), midnight),
      // 11:30 PM.
      (utc.date(2026, 3, 9, 4, 30), midnight),
    ]
    for (now, reload) in cases {
      let result = plan(from: calendar.date(2026, 3, 1), now: now)
      #expect(result.reloadDate == reload)
      let dates = result.entries.map { $0.date }
      #expect(dates == [now, midnight])
    }
  }

  @Test("After moving from Chicago to Tokyo, the reload and the entries' days follow Tokyo")
  func reloadAfterTimeZoneChange() throws {
    let tokyo = Calendar.gregorian("Asia/Tokyo")
    let container = try RunwayModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    context.insert(
      Budget(
        periodLength: .biweekly,
        periodStart: calendar.date(2026, 6, 1),
        spendablePerPeriodCents: 140_000,
        timeZoneIdentifier: calendar.timeZone.identifier
      )
    )
    try context.save()

    func tokyoPlan(now: Date) -> WidgetTimelinePlan {
      WidgetTimelineBuilder.plan(
        loadContainer: { container },
        amountsArePrivate: false,
        now: now,
        calendar: tokyo
      )
    }

    // 9:30 AM June 10 in Chicago is 11:30 PM in Tokyo, half an hour before its midnight.
    let lateInTokyo = utc.date(2026, 6, 10, 14, 30)
    let tokyoMidnight = utc.date(2026, 6, 10, 15)
    let late = tokyoPlan(now: lateInTokyo)
    #expect(late.reloadDate == tokyoMidnight)
    let lateDates = late.entries.map { $0.date }
    #expect(lateDates == [lateInTokyo, tokyoMidnight])
    let lateDays = allowances(in: late).map { $0.daysLeft }
    #expect(lateDays == [5, 4])

    // Noon June 10 in Chicago is already 2 AM June 11 in Tokyo, a day further into the period.
    let noonInChicago = calendar.date(2026, 6, 10, 12)
    let next = tokyoPlan(now: noonInChicago)
    #expect(next.reloadDate == utc.date(2026, 6, 10, 18))
    let nextDates = next.entries.map { $0.date }
    #expect(nextDates == [noonInChicago, utc.date(2026, 6, 11, 15)])
    let nextDays = allowances(in: next).map { $0.daysLeft }
    #expect(nextDays == [4, 3])
  }

  @Test("No budget uses the same reload date")
  func reloadWithNoBudget() throws {
    let container = try RunwayModelContainer.make(inMemory: true)
    let cases: [(now: Date, reload: Date)] = [
      (calendar.date(2026, 6, 10, 12), calendar.date(2026, 6, 10, 13)),
      (calendar.date(2026, 6, 10, 23, 30), calendar.date(2026, 6, 11)),
    ]
    for (now, reload) in cases {
      let result = WidgetTimelineBuilder.plan(
        loadContainer: { container },
        amountsArePrivate: false,
        now: now,
        calendar: calendar
      )
      #expect(result.reloadDate == reload)
    }
  }

  @Test("A store that can't be read still retries in 15 minutes, even past midnight")
  func retryKeepsItsInterval() {
    let now = calendar.date(2026, 6, 10, 23, 50)
    let result = WidgetTimelineBuilder.plan(
      loadContainer: { throw RunwayStoreError.storeNotReady },
      amountsArePrivate: false,
      now: now,
      calendar: calendar
    )
    #expect(result.reloadDate == calendar.date(2026, 6, 11, 0, 5))
  }

  // MARK: - Period boundaries

  @Test("The last day's midnight entry is already in the new period")
  func periodBoundary() {
    let now = calendar.date(2026, 6, 14, 12)
    let boundary = calendar.date(2026, 6, 15)
    let result = plan(from: calendar.date(2026, 6, 1), now: now)

    let dates = result.entries.map { $0.date }
    #expect(dates == [now, boundary])
    #expect(result.reloadDate == now.addingTimeInterval(hour))
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

  @Test("Expense, extra money, bill, budget, time zone, import, and reset saves all fire")
  func everyMutationFires() throws {
    let calendar = Calendar.gregorian("America/Chicago")
    let now = calendar.date(2026, 6, 10, 12)
    let container = try RunwayModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    let service = CategoryService(context: context)
    try service.seed()
    let budget = Budget(
      periodLength: .biweekly,
      periodStart: calendar.date(2026, 6, 1),
      spendablePerPeriodCents: 140_000,
      timeZoneIdentifier: calendar.timeZone.identifier
    )
    context.insert(budget)
    let bill = FixedBill(name: "Phone", amountCents: 4_500)
    context.insert(bill)
    bill.budget = budget
    try context.save()
    let validated = try DataImport.validate(try DataExport.snapshot(of: context))

    // Other tests save at the same time, on any thread, so count only this store's saves.
    let fired = OSAllocatedUnfairLock(initialState: 0)
    let subscription = WidgetReloader.triggers().sink { @Sendable notification in
      guard (notification.object as? ModelContext)?.container === container else { return }
      fired.withLock { $0 += 1 }
    }
    defer { subscription.cancel() }

    func fires(during change: () throws -> Void) throws -> Int {
      let before = fired.withLock { $0 }
      try change()
      return fired.withLock { $0 } - before
    }

    let expense = try fires {
      try service.createExpense(amountCents: 2_500, date: now, now: now)
      try context.save()
    }
    #expect(expense > 0)
    let extraMoney = try fires {
      budget.addExtraMoney(cents: 5_000, note: "Refund", now: now, calendar: calendar)
      try context.save()
    }
    #expect(extraMoney > 0)
    let billMark = try fires {
      budget.setStatus(.paid(cents: 4_500), of: bill, now: now, calendar: calendar)
      try context.save()
    }
    #expect(billMark > 0)
    let schedule = try fires {
      budget.updatePeriod(.monthly, start: calendar.date(2026, 6, 1), now: now, calendar: calendar)
      try context.save()
    }
    #expect(schedule > 0)
    let timeZone = try fires {
      budget.adoptTimeZone(of: Calendar.gregorian("Asia/Tokyo"))
      try context.save()
    }
    #expect(timeZone > 0)
    // Both of these save a scratch context rather than this one.
    let imported = try fires {
      try DataImport.apply(validated, to: context)
    }
    #expect(imported > 0)
    let reset = try fires {
      try DataReset.reset(in: context)
    }
    #expect(reset > 0)
  }
}
