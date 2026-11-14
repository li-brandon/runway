import Foundation
import SwiftData
import Testing

@testable import Runway

/// Card payoff schedules: running totals, payday splits, autopay warnings, and monthly spend.
struct PayoffScheduleTests {
  let calendar = Calendar.gregorian("America/Chicago")

  private func makeContext() throws -> ModelContext {
    ModelContext(try RunwayModelContainer.make(inMemory: true))
  }

  private func card(
    _ name: String,
    due: Int,
    balance: Int?,
    autopay: Bool = false
  ) -> CreditCard {
    let card = CreditCard(name: name, statementDay: 1, dueDay: due, autopay: autopay)
    card.statementBalanceCents = balance
    return card
  }

  private func schedule(
    _ cards: [CreditCard],
    now: Date,
    payday: Date? = nil
  ) -> CardPayoffSchedule {
    CardPayoffSchedule(cards: cards, now: now, nextPayday: payday, calendar: calendar)
  }

  /// Biweekly paydays every other Friday from June 5, 2026.
  private func biweekly(from start: Date? = nil) -> BudgetSnapshot {
    BudgetSnapshot(
      periodLength: .biweekly,
      periodStart: start ?? calendar.date(2026, 6, 5),
      spendablePerPeriodCents: 100_000
    )
  }

  private func payday(_ budget: BudgetSnapshot, _ now: Date) -> Date {
    CardPayoffSchedule.nextPayday(after: now, of: budget, calendar: calendar)
  }

  // MARK: - Running totals

  @Test("Payments run by due date, then name, totaling the cash needed by each date")
  func runningTotals() {
    let cards = [
      card("Month End", due: 31, balance: 10_000),
      card("Early B", due: 5, balance: 20_000),
      card("No Balance", due: 3, balance: nil),
      card("Paid Off", due: 4, balance: 0),
      card("Early A", due: 5, balance: 5_000),
      card("Today", due: 1, balance: 3_000),
    ]
    // A 31st due date falls on February's last day.
    let payments = schedule(cards, now: calendar.date(2026, 2, 1, 9)).payments
    #expect(payments.map(\.name) == ["Today", "Early A", "Early B", "Month End"])
    #expect(
      payments.map(\.dueDate) == [
        calendar.date(2026, 2, 1), calendar.date(2026, 2, 5), calendar.date(2026, 2, 5),
        calendar.date(2026, 2, 28),
      ]
    )
    #expect(payments.map(\.amountCents) == [3_000, 5_000, 20_000, 10_000])
    #expect(payments.map(\.cashNeededCents) == [3_000, 28_000, 28_000, 38_000])
    #expect(payments.map(\.daysLeft) == [0, 4, 4, 27])
  }

  @Test("Payments sharing a due date share the cash needed by it, first date or not")
  func sharedDueDates() {
    let now = calendar.date(2026, 6, 10, 12)
    let paydate = payday(biweekly(), now)

    let middle = schedule(
      [
        card("Later", due: 25, balance: 4_000),
        card("Shared B", due: 15, balance: 3_000),
        card("Solo", due: 12, balance: 1_000),
        card("Shared A", due: 15, balance: 2_000),
      ],
      now: now,
      payday: paydate
    )
    #expect(middle.payments.map(\.name) == ["Solo", "Shared A", "Shared B", "Later"])
    #expect(middle.payments.map(\.cashNeededCents) == [1_000, 6_000, 6_000, 10_000])
    #expect(middle.beforePayday.map(\.name) == ["Solo", "Shared A", "Shared B"])
    #expect(middle.dueBeforePaydayCents == 6_000)
    #expect(middle.dueBeforePaydayCents == middle.beforePayday.last?.cashNeededCents)

    let first = schedule(
      [
        card("Next", due: 20, balance: 2_000),
        card("First B", due: 11, balance: 500),
        card("First A", due: 11, balance: 1_500),
      ],
      now: now,
      payday: paydate
    )
    #expect(first.payments.map(\.name) == ["First A", "First B", "Next"])
    #expect(first.payments.map(\.cashNeededCents) == [2_000, 2_000, 4_000])
    #expect(first.beforePayday.map(\.name) == ["First A", "First B"])
    #expect(first.dueBeforePaydayCents == 2_000)
    #expect(first.dueBeforePaydayCents == first.beforePayday.last?.cashNeededCents)
  }

  @Test("Due dates wrap past January 31, the year end, and a leap day")
  func monthEnds() {
    // January 30 has passed, so the 30th falls on February 28; the 31st is today.
    let january = schedule(
      [card("Thirtieth", due: 30, balance: 1_000), card("Last Day", due: 31, balance: 2_000)],
      now: calendar.date(2026, 1, 31, 12)
    ).payments
    #expect(january.map(\.name) == ["Last Day", "Thirtieth"])
    #expect(january.map(\.dueDate) == [calendar.date(2026, 1, 31), calendar.date(2026, 2, 28)])
    #expect(january.map(\.cashNeededCents) == [2_000, 3_000])

    let december = schedule(
      [card("New Year", due: 3, balance: 7_500), card("Holiday", due: 31, balance: 5_000)],
      now: calendar.date(2026, 12, 20, 12)
    ).payments
    #expect(december.map(\.dueDate) == [calendar.date(2026, 12, 31), calendar.date(2027, 1, 3)])
    #expect(december.map(\.cashNeededCents) == [5_000, 12_500])

    let leap = schedule(
      [card("March", due: 1, balance: 400), card("Leap", due: 31, balance: 600)],
      now: calendar.date(2028, 2, 10)
    ).payments
    #expect(leap.map(\.dueDate) == [calendar.date(2028, 2, 29), calendar.date(2028, 3, 1)])
    #expect(leap.map(\.cashNeededCents) == [600, 1_000])
  }

  // MARK: - Payday

  @Test("Biweekly paydays come from the budget's schedule, across month and year ends")
  func biweeklyPaydays() {
    let budget = biweekly()
    #expect(payday(budget, calendar.date(2026, 6, 10, 12)) == calendar.date(2026, 6, 19))
    // On payday, the next one is two weeks out.
    #expect(payday(budget, calendar.date(2026, 6, 19, 8)) == calendar.date(2026, 7, 3))
    #expect(payday(budget, calendar.date(2026, 6, 25, 12)) == calendar.date(2026, 7, 3))
    #expect(payday(budget, calendar.date(2026, 12, 28, 12)) == calendar.date(2027, 1, 1))
    // Before the budget starts, its first day is the next payday.
    #expect(payday(budget, calendar.date(2026, 6, 1, 12)) == calendar.date(2026, 6, 5))
  }

  @Test("Payments due before a mid-month payday are split out; one due on payday isn't")
  func beforeMidMonthPayday() {
    let now = calendar.date(2026, 6, 10, 12)
    let cards = [
      card("After", due: 25, balance: 5_000),
      card("On Payday", due: 19, balance: 20_000),
      card("Before", due: 15, balance: 10_000),
      card("Day Before", due: 18, balance: 1_000),
    ]
    let result = schedule(cards, now: now, payday: payday(biweekly(), now))
    #expect(result.nextPayday == calendar.date(2026, 6, 19))
    #expect(result.beforePayday.map(\.name) == ["Before", "Day Before"])
    #expect(result.afterPayday.map(\.name) == ["On Payday", "After"])
    #expect(result.dueBeforePaydayCents == 11_000)
    #expect(result.payments.map(\.cashNeededCents) == [10_000, 11_000, 31_000, 36_000])
    #expect(result.dueBeforePaydayCents == result.beforePayday.last?.cashNeededCents)
  }

  @Test("Payments due before a payday in the next month include the month's end")
  func beforePaydayAcrossMonthEnd() {
    let now = calendar.date(2026, 6, 25, 12)
    let cards = [
      card("July Third", due: 3, balance: 4_000),
      card("Late June", due: 20, balance: 8_000),
      card("June End", due: 30, balance: 1_000),
      card("July First", due: 1, balance: 2_000),
    ]
    let result = schedule(cards, now: now, payday: payday(biweekly(), now))
    #expect(result.nextPayday == calendar.date(2026, 7, 3))
    #expect(result.payments.map(\.name) == ["June End", "July First", "July Third", "Late June"])
    #expect(result.beforePayday.map(\.name) == ["June End", "July First"])
    #expect(result.dueBeforePaydayCents == 3_000)
    #expect(result.payments.map(\.cashNeededCents) == [1_000, 3_000, 7_000, 15_000])
    #expect(result.dueBeforePaydayCents == result.beforePayday.last?.cashNeededCents)
  }

  @Test("Without a budget there's no payday, so nothing is due before it")
  func noBudget() throws {
    let now = calendar.date(2026, 6, 10, 12)
    let none: Budget? = nil
    #expect(CardPayoffSchedule.nextPayday(after: now, of: none, calendar: calendar) == nil)

    let result = schedule([card("Soon", due: 11, balance: 1_000)], now: now)
    #expect(result.beforePayday.isEmpty && result.dueBeforePaydayCents == 0)
    #expect(result.afterPayday.map(\.name) == ["Soon"])

    // A saved budget gives the same payday as its snapshot.
    let context = try makeContext()
    let budget = Budget(periodStart: calendar.date(2026, 6, 5), spendablePerPeriodCents: 100_000)
    context.insert(budget)
    try context.save()
    let saved = CardPayoffSchedule.nextPayday(after: now, of: budget, calendar: calendar)
    #expect(saved == calendar.date(2026, 6, 19))
  }

  // MARK: - Autopay

  @Test("A card without autopay is flagged when due within 3 days, today included")
  func autopayAttention() {
    let cards = [
      card("Four", due: 14, balance: 100),
      card("Three", due: 13, balance: 100),
      card("Today", due: 10, balance: 100),
      card("Autopay", due: 10, balance: 100, autopay: true),
    ]
    let payments = schedule(cards, now: calendar.date(2026, 6, 10, 23)).payments
    #expect(payments.map(\.name) == ["Autopay", "Today", "Three", "Four"])
    #expect(payments.map(\.daysLeft) == [0, 0, 3, 4])
    #expect(payments.map(\.needsAutopayAttention) == [false, true, true, false])
  }

  // MARK: - Monthly spend

  @Test("Spend compares this month with last, across the year end, at local midnight")
  func monthlySpend() throws {
    let context = try makeContext()
    let visa = CreditCard(name: "Visa", statementDay: 1, dueDay: 25)
    let amex = CreditCard(name: "Amex", statementDay: 1, dueDay: 25)
    let unused = CreditCard(name: "Unused", statementDay: 1, dueDay: 25)
    context.insert(visa)
    context.insert(amex)
    context.insert(unused)
    let service = CategoryService(context: context)
    let now = calendar.date(2027, 1, 15, 12)

    func purchase(_ cents: Int, _ date: Date, _ card: CreditCard?) throws {
      try service.createExpense(amountCents: cents, date: date, now: now, creditCard: card)
    }
    try purchase(1_000, calendar.date(2027, 1, 1), visa)
    try purchase(2_000, calendar.date(2026, 12, 31, 23, 59, 59), visa)
    try purchase(4_000, calendar.date(2026, 12, 1), visa)
    // Two months ago, and next month.
    try purchase(8_000, calendar.date(2026, 11, 30, 23, 59, 59), visa)
    try purchase(16_000, calendar.date(2027, 2, 1), visa)
    try purchase(300, calendar.date(2027, 1, 31, 23, 59, 59), amex)
    // Not linked to a card.
    try purchase(9_999, calendar.date(2027, 1, 10), nil)
    // Payments aren't spending, so a card with only a payment isn't listed.
    try visa.logPayment(cents: 50_000, date: calendar.date(2027, 1, 10), in: context, now: now)
    try unused.logPayment(cents: 7_000, date: calendar.date(2026, 12, 10), in: context, now: now)
    try context.save()

    let expenses = try context.fetch(FetchDescriptor<Expense>())
    let summary = CardMonthlySpend.summary(of: expenses, now: now, calendar: calendar)
    #expect(summary.map(\.name) == ["Amex", "Visa"])
    #expect(summary.map(\.thisMonthCents) == [300, 1_000])
    #expect(summary.map(\.lastMonthCents) == [0, 6_000])
  }
}
