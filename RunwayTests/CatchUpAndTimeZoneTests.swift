import Foundation
import SwiftData
import Testing

@testable import Runway

/// A time zone move for rows on a 2026 day when Chicago's clocks change. Chicago's midnight is
/// 6 AM UTC on March 8 (still CST) and 5 AM UTC on November 1 (still CDT); London's is midnight
/// UTC on both.
struct DSTMove: Sendable, CustomTestStringConvertible {
  let from: String
  let to: String
  let month: Int
  let day: Int
  let midnightUTCHour: Int

  var testDescription: String { "\(from) to \(to), 2026-\(month)-\(day)" }

  static let all = [
    DSTMove(from: "UTC", to: "America/Chicago", month: 3, day: 8, midnightUTCHour: 6),
    DSTMove(from: "UTC", to: "America/Chicago", month: 11, day: 1, midnightUTCHour: 5),
    DSTMove(from: "Pacific/Honolulu", to: "America/Chicago", month: 3, day: 8, midnightUTCHour: 6),
    DSTMove(from: "Pacific/Honolulu", to: "America/Chicago", month: 11, day: 1, midnightUTCHour: 5),
    DSTMove(from: "America/Chicago", to: "Europe/London", month: 3, day: 8, midnightUTCHour: 0),
    DSTMove(from: "America/Chicago", to: "Europe/London", month: 11, day: 1, midnightUTCHour: 0),
  ]
}

/// Opening the app after days or periods away, and moving between time zones. Weekly $700
/// budgets anchored Monday 2026-06-01.
struct CatchUpAndTimeZoneTests {
  let chicago = Calendar.gregorian("America/Chicago")
  let losAngeles = Calendar.gregorian("America/Los_Angeles")
  let tokyo = Calendar.gregorian("Asia/Tokyo")
  let container: ModelContainer

  init() throws {
    container = try RunwayModelContainer.make(inMemory: true)
  }

  func weekly(_ calendar: Calendar) -> BudgetSnapshot {
    BudgetSnapshot(
      periodLength: .weekly,
      periodStart: calendar.date(2026, 6, 1),
      spendablePerPeriodCents: 70_000
    )
  }

  func makeBudget(in context: ModelContext) throws -> Budget {
    let budget = Budget(
      periodLength: .weekly,
      periodStart: chicago.date(2026, 6, 1),
      spendablePerPeriodCents: 70_000,
      timeZoneIdentifier: "America/Chicago"
    )
    context.insert(budget)
    try context.save()
    return budget
  }

  /// A budget in `calendar`'s time zone with extra money and a bill mark stored at exactly `date`.
  /// Built directly because `addExtraMoney` and `setStatus` now store local midnight, while older
  /// rows can hold any time of day.
  func legacyRows(
    at date: Date,
    in calendar: Calendar,
    context: ModelContext
  ) throws -> (budget: Budget, extra: ExtraMoney, mark: BillPayment) {
    let budget = Budget(
      periodLength: .weekly,
      periodStart: calendar.startOfDay(for: date),
      spendablePerPeriodCents: 70_000,
      timeZoneIdentifier: calendar.timeZone.identifier
    )
    context.insert(budget)
    let extra = ExtraMoney(amountCents: 15_000, note: "Gift", date: date)
    context.insert(extra)
    budget.extraMoney.append(extra)
    let mark = BillPayment(
      isSkipped: true,
      plannedCents: 30_000,
      paidCents: 0,
      adjustmentCents: 30_000,
      sequence: 0,
      date: date
    )
    context.insert(mark)
    budget.billPayments.append(mark)
    try context.save()
    return (budget, extra, mark)
  }

  // MARK: - Catching up

  @Test("Opening after days away catches up the allowance and carryover across boundaries")
  func catchUpAcrossBoundaries() {
    let engine = AllowanceEngine(calendar: chicago)
    let budget = weekly(chicago)
    let monday = [expense(10_000, chicago.date(2026, 6, 1, 12))]
    // Not opened since Monday; Friday: (700 - 100) / 3.
    let friday = engine.currentAllowance(
      budget: budget,
      expenses: monday,
      now: chicago.date(2026, 6, 5, 9)
    )
    #expect(friday.allowanceTodayCents == 20_000)

    // Two boundaries later: Jun 1–7 leaves 200, Jun 8–14 leaves 700 + 200 - 1,000 = -100.
    let expenses = [
      expense(50_000, chicago.date(2026, 6, 3, 12)),
      expense(100_000, chicago.date(2026, 6, 10, 12)),
    ]
    let result = engine.currentAllowance(
      budget: budget,
      expenses: expenses,
      now: chicago.date(2026, 6, 17, 9)
    )
    #expect(result.period.index == 2)
    #expect(result.carryInCents == -10_000)
    // (700 - 100) / 5 days (Jun 17–21).
    #expect(result.allowanceTodayCents == 12_000)
  }

  @Test("A carryover change that took effect while the app was closed applies on open")
  func carryoverChangeWhileAway() throws {
    let context = ModelContext(container)
    let budget = try makeBudget(in: context)
    budget.setCarryover(false, now: chicago.date(2026, 6, 3, 12), calendar: chicago)
    try context.save()

    let result = AllowanceEngine(calendar: chicago).currentAllowance(
      budget: BudgetSnapshot(budget),
      expenses: [expense(50_000, chicago.date(2026, 6, 3, 12))],
      now: chicago.date(2026, 6, 17, 9)
    )
    #expect(result.carryInCents == 0)
    #expect(result.allowanceTodayCents == 14_000)
  }

  @Test("Amount and schedule changes chain correctly through periods missed while away")
  func changesThenAway() throws {
    let context = ModelContext(container)
    let budget = try makeBudget(in: context)
    let expenses = [expense(10_000, chicago.date(2026, 6, 2, 12))]

    // Wednesday Jun 3: spendable up to $1,050 from today.
    var draft = BudgetDraft(budget: budget, locale: Money.fixedLocale)
    draft.spendableText = "1050"
    #expect(draft.apply(to: budget, now: chicago.date(2026, 6, 3, 12), calendar: chicago))
    // Wednesday Jun 10: biweekly from today.
    draft = BudgetDraft(budget: budget, locale: Money.fixedLocale)
    draft.periodLength = .biweekly
    draft.periodStart = chicago.date(2026, 6, 10)
    #expect(draft.apply(to: budget, now: chicago.date(2026, 6, 10, 12), calendar: chicago))
    try context.save()
    #expect(budget.amountChanges.count == 1)
    #expect(budget.scheduleChanges.count == 1)

    // Next opened Tuesday Jun 30.
    let now = chicago.date(2026, 6, 30, 9)
    let result = AllowanceEngine(calendar: chicago).currentAllowance(
      budget: BudgetSnapshot(budget),
      expenses: expenses,
      now: now
    )
    // Jun 1–7: 1,050 - 100 = 950. Jun 8–9: 1,050 × 2 / 7 = 300, so 1,250. Jun 10–23: 1,050,
    // so 2,300. Jun 24 – Jul 7: (1,050 + 2,300) / 8 days left.
    #expect(result.period.index == 3)
    #expect(result.period.start == chicago.date(2026, 6, 24))
    #expect(result.carryInCents == 230_000)
    #expect(result.allowanceTodayCents == 41_875)

    let periods = HistoryEngine(calendar: chicago).periods(
      budget: BudgetSnapshot(budget),
      expenses: expenses.map { historyExpense($0.amountCents, $0.date) },
      now: now
    )
    #expect(periods.map(\.carryOutCents) == [nil, 230_000, 125_000, 95_000])
    #expect(periods.map(\.carryInCents) == [230_000, 125_000, 95_000, 0])
  }

  // MARK: - Time zones

  @Test("The day boundary follows the calendar's time zone")
  func dayBoundaryFollowsTimeZone() {
    // 11:30 PM Thursday in Los Angeles is 1:30 AM Friday in Chicago.
    let lateThursday = losAngeles.date(2026, 6, 4, 23, 30)
    let expenses = [expense(5_000, lateThursday)]

    let inLosAngeles = AllowanceEngine(calendar: losAngeles).currentAllowance(
      budget: weekly(losAngeles),
      expenses: expenses,
      now: lateThursday
    )
    #expect(inLosAngeles.spentTodayCents == 5_000)
    #expect(inLosAngeles.daysLeft == 4)

    let inChicago = AllowanceEngine(calendar: chicago).currentAllowance(
      budget: weekly(chicago),
      expenses: expenses,
      now: lateThursday
    )
    #expect(inChicago.spentTodayCents == 5_000)
    #expect(inChicago.daysLeft == 3)
  }

  @Test("Moving time zones keeps paydays and change dates on the same calendar days")
  func adoptTimeZone() throws {
    let context = ModelContext(container)
    let budget = try makeBudget(in: context)
    let wednesday = chicago.date(2026, 6, 3, 12)
    budget.setCarryover(false, now: wednesday, calendar: chicago)
    budget.updatePeriod(.weekly, start: chicago.date(2026, 6, 5), now: wednesday, calendar: chicago)
    var draft = BudgetDraft(budget: budget, locale: Money.fixedLocale)
    draft.spendableText = "800"
    #expect(draft.apply(to: budget, now: wednesday, calendar: chicago))
    try context.save()

    // Without adopting, Los Angeles reads Chicago's midnight as 10 PM the day before.
    let stale = AllowanceEngine(calendar: losAngeles).period(at: 0, of: BudgetSnapshot(budget))
    #expect(stale.start == losAngeles.date(2026, 5, 31))

    #expect(budget.adoptTimeZone(of: losAngeles))
    try context.save()
    #expect(budget.timeZoneIdentifier == "America/Los_Angeles")
    #expect(budget.periodStart == losAngeles.date(2026, 6, 5))
    let change = try #require(budget.scheduleChanges.first)
    #expect(change.previousPeriodStart == losAngeles.date(2026, 6, 1))
    #expect(change.effectiveAt == losAngeles.date(2026, 6, 3))
    #expect(budget.carryoverChanges.map(\.effectiveAt) == [losAngeles.date(2026, 6, 5)])
    #expect(budget.amountChanges.map(\.effectiveAt) == [losAngeles.date(2026, 6, 3)])
    #expect(!budget.adoptTimeZone(of: losAngeles))

    let engine = AllowanceEngine(calendar: losAngeles)
    let periods = engine.periods(
      through: losAngeles.date(2026, 6, 5, 9),
      of: BudgetSnapshot(budget)
    )
    #expect(periods.map(\.start) == [1, 3, 5].map { losAngeles.date(2026, 6, $0) })

    let localAllowance = engine.currentAllowance(
      budget: BudgetSnapshot(budget),
      expenses: [],
      now: losAngeles.date(2026, 6, 5, 9)
    )
    #expect(localAllowance.daysLeft == 7)
    #expect(localAllowance.carryInCents == 0)
    #expect(localAllowance.allowanceTodayCents == 11_428)

    // Tokyo is ahead of Chicago; the days stay put there too.
    #expect(budget.adoptTimeZone(of: tokyo))
    #expect(budget.periodStart == tokyo.date(2026, 6, 5))
    #expect(budget.scheduleChanges.first?.effectiveAt == tokyo.date(2026, 6, 3))
  }

  @Test("A UTC-10 to UTC+14 move keeps extra money, bill marks, and period totals in place")
  func largeJumpKeepsExtraMoneyAndBillMarks() throws {
    let honolulu = Calendar.gregorian("Pacific/Honolulu")
    let kiritimati = Calendar.gregorian("Pacific/Kiritimati")
    let context = ModelContext(container)
    // $700 available a week: $1,000 minus a $300 Rent bill.
    let budget = Budget(
      periodLength: .weekly,
      periodStart: honolulu.date(2026, 6, 1),
      spendablePerPeriodCents: 100_000,
      timeZoneIdentifier: "Pacific/Honolulu"
    )
    context.insert(budget)
    let rent = FixedBill(name: "Rent", amountCents: 30_000, dueDay: 1)
    context.insert(rent)
    budget.fixedBills.append(rent)

    // Late on the period's last day. Unmoved, midnight in Honolulu reads as the next day, and so
    // the next period, on Kiritimati.
    let lateSunday = honolulu.date(2026, 6, 7, 23, 30)
    let gift = budget.addExtraMoney(
      cents: 15_000,
      note: "Gift",
      now: lateSunday,
      calendar: honolulu
    )
    budget.setStatus(.skipped, of: rent, now: lateSunday, calendar: honolulu)
    try context.save()
    let mark = try #require(budget.billPayments.first)
    #expect(gift.date == honolulu.date(2026, 6, 7))
    #expect(mark.date == honolulu.date(2026, 6, 7))

    // No expenses: they keep their instants, so a move can shift them to another local day.
    // Remaining, allowance, and History's remaining per period (newest first), late on Sunday and
    // on Monday morning, at the same wall-clock times in either zone.
    func figures(_ calendar: Calendar) -> [Int] {
      let snapshot = BudgetSnapshot(budget)
      let times = [calendar.date(2026, 6, 7, 23, 30), calendar.date(2026, 6, 8, 9)]
      return times.flatMap { now -> [Int] in
        let result = AllowanceEngine(calendar: calendar).currentAllowance(
          budget: snapshot,
          expenses: [],
          now: now
        )
        let history = HistoryEngine(calendar: calendar).periods(
          budget: snapshot,
          expenses: [HistoryExpense<String>](),
          now: now
        )
        return [result.remainingPeriodCents, result.allowanceTodayCents]
          + history.map(\.remainingCents)
      }
    }

    // Sunday: 700 + 150 + 300 skipped, 1 day left. Monday: 700 + 1,150 carried in, over 7 days.
    let before = figures(honolulu)
    #expect(before == [115_000, 115_000, 115_000, 185_000, 26_428, 185_000, 115_000])

    #expect(budget.adoptTimeZone(of: kiritimati))
    try context.save()

    #expect(gift.date == kiritimati.date(2026, 6, 7))
    #expect(mark.date == kiritimati.date(2026, 6, 7))
    #expect(figures(kiritimati) == before)

    let period = AllowanceEngine(calendar: kiritimati).period(
      containing: kiritimati.date(2026, 6, 7, 23, 30),
      of: BudgetSnapshot(budget)
    )
    #expect(period.start == kiritimati.date(2026, 6, 1))
    #expect(budget.extraMoneyItems(in: period).map(\.note) == ["Gift"])
    #expect(budget.status(of: rent, in: period) == .skipped)
  }

  @Test(
    "Legacy rows saved at a time of day move to the new zone's midnight on the same day",
    arguments: ["Asia/Tokyo", "America/New_York"],
    [23, 0]
  )
  func legacyRowsKeepCalendarDay(destination: String, hour: Int) throws {
    let honolulu = Calendar.gregorian("Pacific/Honolulu")
    let target = Calendar.gregorian(destination)
    let context = ModelContext(container)
    // 11:30 PM on Jun 7 in Honolulu is already Jun 8 in both destinations.
    let saved = honolulu.date(2026, 6, 7, hour, 30)
    let rows = try legacyRows(at: saved, in: honolulu, context: context)
    #expect(rows.extra.date == saved)
    #expect(rows.mark.date == saved)

    #expect(rows.budget.adoptTimeZone(of: target))
    try context.save()

    #expect(rows.budget.timeZoneIdentifier == destination)
    #expect(rows.extra.date == target.date(2026, 6, 7))
    #expect(rows.mark.date == target.date(2026, 6, 7))
  }

  @Test(
    "Rows on DST days keep their calendar day moving into and out of Chicago",
    arguments: DSTMove.all,
    [0, 3, 23]
  )
  func dstDayRowsKeepCalendarDay(move: DSTMove, hour: Int) throws {
    let source = Calendar.gregorian(move.from)
    let target = Calendar.gregorian(move.to)
    let context = ModelContext(container)
    // 12:30, 3:30, and 11:30 are neither skipped nor repeated on either day.
    let saved = source.date(2026, move.month, move.day, hour, 30)
    let rows = try legacyRows(at: saved, in: source, context: context)

    #expect(rows.budget.adoptTimeZone(of: target))
    try context.save()

    let midnight = target.date(2026, move.month, move.day)
    let utc = Calendar.gregorian("UTC")
    #expect(midnight == utc.date(2026, move.month, move.day, move.midnightUTCHour))
    #expect(rows.extra.date == midnight)
    #expect(rows.mark.date == midnight)
    #expect(rows.budget.periodStart == midnight)
  }

  @Test(
    "Rows in either pass of Chicago's repeated 1:30 AM keep the fall-back day",
    arguments: [1.5, 2.5]
  )
  func repeatedHourRowsKeepCalendarDay(hoursAfterMidnight: Double) throws {
    let london = Calendar.gregorian("Europe/London")
    let context = ModelContext(container)
    // Offsets from midnight, because the `date` helper can't choose between the two passes.
    let saved = chicago.date(2026, 11, 1).addingTimeInterval(hoursAfterMidnight * 3_600)
    #expect(chicago.component(.hour, from: saved) == 1)
    #expect(chicago.component(.minute, from: saved) == 30)
    let rows = try legacyRows(at: saved, in: chicago, context: context)

    #expect(rows.budget.adoptTimeZone(of: london))
    try context.save()

    #expect(rows.extra.date == london.date(2026, 11, 1))
    #expect(rows.mark.date == london.date(2026, 11, 1))
  }

  @Test("A budget without a recorded time zone just records the current one")
  func adoptFirstTimeZone() throws {
    let budget = Budget(periodStart: chicago.date(2026, 6, 1), spendablePerPeriodCents: 70_000)
    #expect(budget.timeZoneIdentifier.isEmpty)
    #expect(budget.adoptTimeZone(of: chicago))
    #expect(budget.timeZoneIdentifier == "America/Chicago")
    #expect(budget.periodStart == chicago.date(2026, 6, 1))

    // A new budget from setup records the time zone it was set up in.
    var draft = BudgetDraft(periodStart: chicago.date(2026, 6, 1), locale: Money.fixedLocale)
    draft.spendableText = "700"
    let context = ModelContext(container)
    let saved = try #require(draft.insertBudget(into: context, calendar: chicago))
    #expect(saved.timeZoneIdentifier == "America/Chicago")
  }
}
