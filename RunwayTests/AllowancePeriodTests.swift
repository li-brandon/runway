import Foundation
import Testing

@testable import Runway

/// Period boundaries, DST and time zones. Chicago is UTC-6 (CST) / UTC-5 (CDT); Auckland is
/// UTC+12 (NZST) / UTC+13 (NZDT). Epoch literals are UTC.
struct AllowancePeriodTests {
  let chicago = Calendar.gregorian("America/Chicago")
  let auckland = Calendar.gregorian("Pacific/Auckland")

  @Test("Spring-forward day (2026-03-08, 23 hours) counts as one day")
  func springForward() {
    let engine = AllowanceEngine(calendar: chicago)
    let budget = BudgetSnapshot(
      periodLength: .weekly,
      periodStart: chicago.date(2026, 3, 8, 15),
      spendablePerPeriodCents: 70_000
    )

    let period = engine.period(at: 0, of: budget)
    #expect(period.start == Date(timeIntervalSince1970: 1_772_949_600))  // 2026-03-08T06:00Z
    #expect(period.end == Date(timeIntervalSince1970: 1_773_550_800))  // 2026-03-15T05:00Z
    #expect(period.end.timeIntervalSince(period.start) == 7 * 86_400 - 3_600)
    #expect(engine.dayCount(from: chicago.date(2026, 3, 8), to: chicago.date(2026, 3, 9)) == 1)

    let expenses = [
      expense(1_000, chicago.date(2026, 3, 8, 1, 30)),  // CST, before the jump
      expense(2_000, chicago.date(2026, 3, 8, 3, 30)),  // CDT, after the jump
      expense(3_000, chicago.date(2026, 3, 8, 23, 59)),
      expense(4_000, chicago.date(2026, 3, 9)),
    ]

    let lateEvening = engine.allowance(
      budget: budget,
      expenses: expenses,
      carryInCents: 0,
      now: chicago.date(2026, 3, 8, 23, 59, 30)
    )
    #expect(lateEvening.daysLeft == 7)
    #expect(lateEvening.allowanceTodayCents == 10_000)
    #expect(lateEvening.spentTodayCents == 6_000)
    #expect(lateEvening.remainingTodayCents == 4_000)
    #expect(lateEvening.remainingPeriodCents == 64_000)

    // 640 / 6 = 106.666…, floored.
    let nextDay = engine.allowance(
      budget: budget,
      expenses: expenses,
      carryInCents: 0,
      now: chicago.date(2026, 3, 9)
    )
    #expect(nextDay.daysLeft == 6)
    #expect(nextDay.allowanceTodayCents == 10_666)
    #expect(nextDay.spentTodayCents == 4_000)
    #expect(nextDay.remainingTodayCents == 6_666)
    #expect(nextDay.remainingPeriodCents == 60_000)
  }

  @Test("Spring-forward day as the last day of a period")
  func springForwardLastDay() {
    let engine = AllowanceEngine(calendar: chicago)
    let budget = BudgetSnapshot(
      periodLength: .weekly,
      periodStart: chicago.date(2026, 3, 2),
      spendablePerPeriodCents: 70_000
    )

    let lastDay = engine.period(containing: chicago.date(2026, 3, 8, 23, 59), of: budget)
    #expect(lastDay.index == 0)
    #expect(lastDay.end == chicago.date(2026, 3, 9))
    #expect(engine.period(containing: chicago.date(2026, 3, 9), of: budget).index == 1)

    let result = engine.allowance(
      budget: budget,
      expenses: [expense(40_000, chicago.date(2026, 3, 4, 12))],
      carryInCents: 0,
      now: chicago.date(2026, 3, 8, 12)
    )
    #expect(result.daysLeft == 1)
    #expect(result.allowanceTodayCents == 30_000)
  }

  @Test("Fall-back day (2026-11-01, 25 hours) counts as one day")
  func fallBack() {
    let engine = AllowanceEngine(calendar: chicago)
    let budget = BudgetSnapshot(
      periodLength: .weekly,
      periodStart: chicago.date(2026, 11, 1),
      spendablePerPeriodCents: 70_000
    )

    let period = engine.period(at: 0, of: budget)
    #expect(period.start == Date(timeIntervalSince1970: 1_793_509_200))  // 2026-11-01T05:00Z
    #expect(period.end == Date(timeIntervalSince1970: 1_794_117_600))  // 2026-11-08T06:00Z
    #expect(period.end.timeIntervalSince(period.start) == 7 * 86_400 + 3_600)

    // 24 hours after midnight is still Nov 1 (23:00 CST).
    let expenses = [
      expense(3_000, period.start.addingTimeInterval(86_400)),
      expense(4_000, chicago.date(2026, 11, 2)),
    ]

    let lateEvening = engine.allowance(
      budget: budget,
      expenses: expenses,
      carryInCents: 0,
      now: chicago.date(2026, 11, 1, 23, 59)
    )
    #expect(lateEvening.daysLeft == 7)
    #expect(lateEvening.allowanceTodayCents == 10_000)
    #expect(lateEvening.spentTodayCents == 3_000)
    #expect(lateEvening.remainingTodayCents == 7_000)

    // 670 / 6 = 111.666…, floored.
    let nextDay = engine.allowance(
      budget: budget,
      expenses: expenses,
      carryInCents: 0,
      now: chicago.date(2026, 11, 2)
    )
    #expect(nextDay.daysLeft == 6)
    #expect(nextDay.allowanceTodayCents == 11_166)
    #expect(nextDay.spentTodayCents == 4_000)
    #expect(nextDay.remainingTodayCents == 7_166)
    #expect(nextDay.remainingPeriodCents == 63_000)
  }

  @Test("Days left are calendar days across a fall-back transition mid-period")
  func fallBackMidPeriod() {
    let engine = AllowanceEngine(calendar: chicago)
    let budget = BudgetSnapshot(
      periodLength: .biweekly,
      periodStart: chicago.date(2026, 10, 23),
      spendablePerPeriodCents: 140_000
    )
    // Nov 1–5 left: (1_400 - 120) / 5 = 256.
    let result = engine.allowance(
      budget: budget,
      expenses: [expense(12_000, chicago.date(2026, 10, 25, 12))],
      carryInCents: 0,
      now: chicago.date(2026, 11, 1, 12)
    )
    #expect(result.periodEnd == chicago.date(2026, 11, 6))
    #expect(result.daysLeft == 5)
    #expect(result.allowanceTodayCents == 25_600)
  }

  @Test("Biweekly periods cross month boundaries")
  func biweeklyAcrossMonths() {
    let engine = AllowanceEngine(calendar: chicago)
    let budget = BudgetSnapshot(
      periodLength: .biweekly,
      periodStart: chicago.date(2026, 6, 22),
      spendablePerPeriodCents: 140_000
    )

    // Jul 1–5 left: (1_400 - 300) / 5 = 220.
    let result = engine.allowance(
      budget: budget,
      expenses: [
        expense(30_000, chicago.date(2026, 6, 30, 23, 59)),
        expense(5_000, chicago.date(2026, 7, 1)),
      ],
      carryInCents: 0,
      now: chicago.date(2026, 7, 1, 8)
    )
    #expect(result.period.index == 0)
    #expect(result.periodStart == chicago.date(2026, 6, 22))
    #expect(result.periodEnd == chicago.date(2026, 7, 6))
    #expect(result.daysLeft == 5)
    #expect(result.allowanceTodayCents == 22_000)
    #expect(result.spentTodayCents == 5_000)
    #expect(result.remainingTodayCents == 17_000)
    #expect(result.remainingPeriodCents == 105_000)

    let second = engine.period(containing: chicago.date(2026, 7, 19, 23, 59), of: budget)
    #expect(second.index == 1)
    #expect(second.start == chicago.date(2026, 7, 6))
    #expect(second.end == chicago.date(2026, 7, 20))

    let third = engine.period(containing: chicago.date(2026, 7, 20), of: budget)
    #expect(third.index == 2)
    #expect(third.start == chicago.date(2026, 7, 20))
    #expect(third.end == chicago.date(2026, 8, 3))
  }

  @Test("Monthly periods anchored on Jan 31 clamp to short months without drifting")
  func monthlyFromJanuary31() {
    let engine = AllowanceEngine(calendar: chicago)
    let budget = BudgetSnapshot(
      periodLength: .monthly,
      periodStart: chicago.date(2026, 1, 31),
      spendablePerPeriodCents: 310_000
    )

    let starts = (0...4).map { engine.period(at: $0, of: budget).start }
    #expect(
      starts == [
        chicago.date(2026, 1, 31),
        chicago.date(2026, 2, 28),
        chicago.date(2026, 3, 31),
        chicago.date(2026, 4, 30),
        chicago.date(2026, 5, 31),
      ]
    )

    let containing = [
      (chicago.date(2026, 1, 31), 0),
      (chicago.date(2026, 2, 27, 23, 59), 0),
      (chicago.date(2026, 2, 28), 1),
      (chicago.date(2026, 3, 30, 12), 1),
      (chicago.date(2026, 3, 31), 2),
      (chicago.date(2026, 4, 29, 23, 59), 2),
      (chicago.date(2026, 4, 30), 3),
    ]
    for (date, index) in containing {
      #expect(engine.period(containing: date, of: budget).index == index)
    }

    // Period 0 leaves 3_100 - 2_000 = 1_100. Period 1 (Feb 28–Mar 30) has 31 days:
    // (3_100 + 1_100) / 31 = 135.483…, floored.
    let result = engine.currentAllowance(
      budget: budget,
      expenses: [expense(200_000, chicago.date(2026, 2, 10, 12))],
      now: chicago.date(2026, 2, 28, 9)
    )
    #expect(result.period.index == 1)
    #expect(result.carryInCents == 110_000)
    #expect(result.daysLeft == 31)
    #expect(result.allowanceTodayCents == 13_548)
    #expect(result.remainingPeriodCents == 420_000)
  }

  @Test("Monthly periods anchored on the 29th clamp to February's last day, then return")
  func monthlyFrom29th() {
    let engine = AllowanceEngine(calendar: chicago)

    let common = monthlyBudget(anchoredOn: chicago.date(2026, 1, 29))
    let commonStarts = (0...3).map { engine.period(at: $0, of: common).start }
    #expect(
      commonStarts == [
        chicago.date(2026, 1, 29),
        chicago.date(2026, 2, 28),
        chicago.date(2026, 3, 29),
        chicago.date(2026, 4, 29),
      ]
    )
    let containing = [
      (chicago.date(2026, 2, 27, 23, 59), 0),
      (chicago.date(2026, 2, 28), 1),
      (chicago.date(2026, 3, 28, 23, 59), 1),
      (chicago.date(2026, 3, 29), 2),
    ]
    for (date, index) in containing {
      #expect(engine.period(containing: date, of: common).index == index)
    }
    // Jan 29–Feb 27 is 30 days; Feb 28–Mar 28 is 29.
    #expect(daysLeft(engine, common, on: chicago.date(2026, 1, 29, 9)) == 30)
    #expect(daysLeft(engine, common, on: chicago.date(2026, 2, 28, 9)) == 29)

    let leap = monthlyBudget(anchoredOn: chicago.date(2028, 1, 29))
    let leapStarts = (0...2).map { engine.period(at: $0, of: leap).start }
    #expect(
      leapStarts == [
        chicago.date(2028, 1, 29),
        chicago.date(2028, 2, 29),
        chicago.date(2028, 3, 29),
      ]
    )
    #expect(engine.period(containing: chicago.date(2028, 2, 28, 23, 59), of: leap).index == 0)
    #expect(engine.period(containing: chicago.date(2028, 2, 29), of: leap).index == 1)
    // Jan 29–Feb 28 is 31 days; Feb 29–Mar 28 is 29.
    #expect(daysLeft(engine, leap, on: chicago.date(2028, 1, 29, 9)) == 31)
    #expect(daysLeft(engine, leap, on: chicago.date(2028, 2, 29, 9)) == 29)
  }

  @Test("Monthly periods anchored on the 30th clamp to February's last day, then return")
  func monthlyFrom30th() {
    let engine = AllowanceEngine(calendar: chicago)

    let common = monthlyBudget(anchoredOn: chicago.date(2026, 1, 30))
    let commonStarts = (0...3).map { engine.period(at: $0, of: common).start }
    #expect(
      commonStarts == [
        chicago.date(2026, 1, 30),
        chicago.date(2026, 2, 28),
        chicago.date(2026, 3, 30),
        chicago.date(2026, 4, 30),
      ]
    )
    let containing = [
      (chicago.date(2026, 2, 27, 23, 59), 0),
      (chicago.date(2026, 2, 28), 1),
      (chicago.date(2026, 3, 29, 23, 59), 1),
      (chicago.date(2026, 3, 30), 2),
    ]
    for (date, index) in containing {
      #expect(engine.period(containing: date, of: common).index == index)
    }
    // Jan 30–Feb 27 is 29 days; Feb 28–Mar 29 is 30.
    #expect(daysLeft(engine, common, on: chicago.date(2026, 1, 30, 9)) == 29)
    #expect(daysLeft(engine, common, on: chicago.date(2026, 2, 28, 9)) == 30)

    let leap = monthlyBudget(anchoredOn: chicago.date(2028, 1, 30))
    let leapStarts = (0...2).map { engine.period(at: $0, of: leap).start }
    #expect(
      leapStarts == [
        chicago.date(2028, 1, 30),
        chicago.date(2028, 2, 29),
        chicago.date(2028, 3, 30),
      ]
    )
    #expect(engine.period(containing: chicago.date(2028, 2, 28, 23, 59), of: leap).index == 0)
    #expect(engine.period(containing: chicago.date(2028, 2, 29), of: leap).index == 1)
    // Jan 30–Feb 28 is 30 days; Feb 29–Mar 29 is 30.
    #expect(daysLeft(engine, leap, on: chicago.date(2028, 1, 30, 9)) == 30)
    #expect(daysLeft(engine, leap, on: chicago.date(2028, 2, 29, 9)) == 30)
  }

  func monthlyBudget(anchoredOn anchor: Date) -> BudgetSnapshot {
    BudgetSnapshot(periodLength: .monthly, periodStart: anchor, spendablePerPeriodCents: 300_000)
  }

  func daysLeft(_ engine: AllowanceEngine, _ budget: BudgetSnapshot, on now: Date) -> Int {
    engine.allowance(budget: budget, expenses: [], carryInCents: 0, now: now).daysLeft
  }

  @Test("Auckland spring-forward day (2026-09-27) counts as one day")
  func aucklandSpringForward() {
    let engine = AllowanceEngine(calendar: auckland)
    let budget = BudgetSnapshot(
      periodLength: .weekly,
      periodStart: auckland.date(2026, 9, 27),
      spendablePerPeriodCents: 70_000
    )

    let period = engine.period(at: 0, of: budget)
    #expect(period.start == Date(timeIntervalSince1970: 1_790_424_000))  // 2026-09-26T12:00Z
    #expect(period.end == Date(timeIntervalSince1970: 1_791_025_200))  // 2026-10-03T11:00Z

    let result = engine.allowance(
      budget: budget,
      expenses: [],
      carryInCents: 0,
      now: auckland.date(2026, 9, 27, 23)
    )
    #expect(result.daysLeft == 7)
    #expect(result.allowanceTodayCents == 10_000)
  }

  @Test("The same instant falls on different local days in different time zones")
  func timeZones() {
    let utc = Calendar.gregorian("UTC")
    // 06:00 Jun 2 in Chicago; 23:00 Jun 2 in Auckland.
    let expenses = [expense(5_000, utc.date(2026, 6, 2, 11))]
    // 15:00 Jun 2 in Chicago; 08:00 Jun 3 in Auckland.
    let now = utc.date(2026, 6, 2, 20)

    let chicagoEngine = AllowanceEngine(calendar: chicago)
    let chicagoResult = chicagoEngine.allowance(
      budget: BudgetSnapshot(
        periodLength: .weekly,
        periodStart: chicago.date(2026, 6, 1),
        spendablePerPeriodCents: 70_000
      ),
      expenses: expenses,
      carryInCents: 0,
      now: now
    )
    #expect(chicagoResult.daysLeft == 6)
    #expect(chicagoResult.allowanceTodayCents == 11_666)
    #expect(chicagoResult.spentTodayCents == 5_000)
    #expect(chicagoResult.remainingTodayCents == 6_666)
    #expect(chicagoResult.remainingPeriodCents == 65_000)

    let aucklandEngine = AllowanceEngine(calendar: auckland)
    let aucklandResult = aucklandEngine.allowance(
      budget: BudgetSnapshot(
        periodLength: .weekly,
        periodStart: auckland.date(2026, 6, 1),
        spendablePerPeriodCents: 70_000
      ),
      expenses: expenses,
      carryInCents: 0,
      now: now
    )
    #expect(aucklandResult.daysLeft == 5)
    #expect(aucklandResult.allowanceTodayCents == 13_000)
    #expect(aucklandResult.spentTodayCents == 0)
    #expect(aucklandResult.remainingTodayCents == 13_000)
    #expect(aucklandResult.remainingPeriodCents == 65_000)
  }
}
