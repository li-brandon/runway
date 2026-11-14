import Foundation
import SwiftData

/// One card's upcoming payment: its statement balance, due on its next due date.
struct ScheduledCardPayment: Identifiable {
  let card: CreditCard
  let name: String
  let amountCents: Int
  /// Local midnight of the next due date.
  let dueDate: Date
  /// Whole days from the start of today to `dueDate`: 0 when it's due today.
  let daysLeft: Int
  /// Every payment due on or before `dueDate`, this card's and others': the cash needed by then.
  /// Payments sharing a due date share this total.
  let cashNeededCents: Int
  /// Due before the next payday. A payment due on payday itself isn't.
  let isBeforePayday: Bool
  /// Autopay is off and the payment is due within 3 days, today included.
  let needsAutopayAttention: Bool

  var id: ObjectIdentifier { ObjectIdentifier(card) }
}

/// Upcoming card payments, soonest due first, with the cash needed by each due date: the total of
/// every payment due on or before it. Days are local days in `calendar`.
struct CardPayoffSchedule {
  /// Days left within which a card without autopay needs attention.
  static let autopayAttentionDays = 0...3

  /// Every card with a statement balance to pay, by next due date, then name.
  let payments: [ScheduledCardPayment]
  /// Local midnight of the next payday, or `nil` without a budget.
  let nextPayday: Date?

  /// Pays each card's statement balance on its next due date. Cards without a positive statement
  /// balance have nothing to pay, so they're skipped. With no `nextPayday`, nothing is before it.
  init(cards: [CreditCard], now: Date, nextPayday: Date?, calendar: Calendar) {
    let due = CreditCardDates.sorted(cards, now: now, calendar: calendar).compactMap {
      card -> (card: CreditCard, amountCents: Int, dueDate: Date)? in
      guard let amountCents = card.statementBalanceCents, amountCents > 0 else { return nil }
      return (card, amountCents, card.nextDueDate(now: now, calendar: calendar))
    }
    // Payments run by due date, so the running total after a date's last payment covers every
    // payment due through that date.
    var cashNeededByDate: [Date: Int] = [:]
    var runningCents = 0
    for payment in due {
      runningCents += payment.amountCents
      cashNeededByDate[payment.dueDate] = runningCents
    }
    payments = due.map { payment in
      let daysLeft = CreditCardDates.daysLeft(until: payment.dueDate, now: now, calendar: calendar)
      return ScheduledCardPayment(
        card: payment.card,
        name: payment.card.name,
        amountCents: payment.amountCents,
        dueDate: payment.dueDate,
        daysLeft: daysLeft,
        cashNeededCents: cashNeededByDate[payment.dueDate]!,
        isBeforePayday: nextPayday.map { payment.dueDate < $0 } ?? false,
        needsAutopayAttention: !payment.card.autopay
          && Self.autopayAttentionDays.contains(daysLeft)
      )
    }
    self.nextPayday = nextPayday
  }

  var beforePayday: [ScheduledCardPayment] { payments.filter(\.isBeforePayday) }

  var afterPayday: [ScheduledCardPayment] { payments.filter { !$0.isBeforePayday } }

  /// The cash needed before the next payday.
  var dueBeforePaydayCents: Int { beforePayday.reduce(0) { $0 + $1.amountCents } }

  /// The start of the next pay period after the start of `now`'s day, from the budget's schedule.
  static func nextPayday(after now: Date, of budget: BudgetSnapshot, calendar: Calendar) -> Date {
    let period = AllowanceEngine(calendar: calendar).period(containing: now, of: budget)
    // Before the budget's first period, its first day is the next payday.
    return calendar.startOfDay(for: now) < period.start ? period.start : period.end
  }

  /// The next payday of `budget`, or `nil` without one.
  static func nextPayday(after now: Date, of budget: Budget?, calendar: Calendar) -> Date? {
    budget.map { nextPayday(after: now, of: BudgetSnapshot($0), calendar: calendar) }
  }
}

/// What was spent on one card in the calendar month containing `now` and in the month before.
struct CardMonthlySpend: Identifiable {
  let card: CreditCard
  let name: String
  let thisMonthCents: Int
  let lastMonthCents: Int

  var id: ObjectIdentifier { ObjectIdentifier(card) }

  /// Purchases linked to each card in this calendar month and the last, by card name. Card
  /// payments pay off spending rather than being spending, so they never count. Only cards with a
  /// purchase in either month are included.
  static func summary(
    of expenses: [Expense],
    now: Date,
    calendar: Calendar
  ) -> [CardMonthlySpend] {
    let thisMonth = calendar.dateInterval(of: .month, for: now)!
    let lastMonthDay = calendar.date(byAdding: .month, value: -1, to: thisMonth.start)!
    let lastMonth = calendar.dateInterval(of: .month, for: lastMonthDay)!
    // `DateInterval.contains` includes its end, which is the next month's first moment.
    func isIn(_ month: DateInterval, _ date: Date) -> Bool {
      month.start <= date && date < month.end
    }

    var totals: [ObjectIdentifier: CardMonthlySpend] = [:]
    for expense in expenses where !expense.isCardPayment {
      guard let card = expense.creditCard else { continue }
      let isThisMonth = isIn(thisMonth, expense.date)
      guard isThisMonth || isIn(lastMonth, expense.date) else { continue }
      let current =
        totals[ObjectIdentifier(card)]
        ?? CardMonthlySpend(card: card, name: card.name, thisMonthCents: 0, lastMonthCents: 0)
      totals[ObjectIdentifier(card)] = CardMonthlySpend(
        card: card,
        name: card.name,
        thisMonthCents: current.thisMonthCents + (isThisMonth ? expense.amountCents : 0),
        lastMonthCents: current.lastMonthCents + (isThisMonth ? 0 : expense.amountCents)
      )
    }
    return totals.values.sorted { $0.name < $1.name }
  }
}
