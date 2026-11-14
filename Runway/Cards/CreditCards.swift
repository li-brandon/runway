import Foundation
import SwiftData

/// Due dates, statement dates, and staleness for credit cards. Days are local days in `calendar`.
enum CreditCardDates {
  /// How long an imported balance stays fresh.
  static let importedFreshness: TimeInterval = 24 * 60 * 60

  /// The next day-of-month `day` on or after the start of `now`'s day. A day past the end of a
  /// month falls on its last day, like a 31st due date in February.
  static func next(day: Int, onOrAfter now: Date, calendar: Calendar) -> Date {
    let today = calendar.startOfDay(for: now)
    let thisMonth = calendar.dateInterval(of: .month, for: today)!.start
    let candidate = date(day: day, inMonthStarting: thisMonth, calendar: calendar)
    guard candidate < today else { return candidate }
    let nextMonth = calendar.date(byAdding: .month, value: 1, to: thisMonth)!
    return date(day: day, inMonthStarting: nextMonth, calendar: calendar)
  }

  /// Whole days from the start of `now`'s day to `date`'s day: 0 when it's today.
  static func daysLeft(until date: Date, now: Date, calendar: Calendar) -> Int {
    let today = calendar.startOfDay(for: now)
    return calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: date)).day!
  }

  /// An imported balance is stale after 24 hours. A manual one is stale once a statement day after
  /// the day it was entered has begun, so one entered on statement day lasts until the next one.
  static func isStale(
    updatedAt: Date?,
    source: CardBalanceSource,
    statementDay: Int,
    now: Date,
    calendar: Calendar
  ) -> Bool {
    guard let updatedAt else { return true }
    switch source {
    case .imported:
      return now.timeIntervalSince(updatedAt) >= importedFreshness
    case .manual:
      let updatedDay = calendar.startOfDay(for: updatedAt)
      let dayAfter = calendar.date(byAdding: .day, value: 1, to: updatedDay)!
      return now >= next(day: statementDay, onOrAfter: dayAfter, calendar: calendar)
    }
  }

  /// Cards by next due date, then name.
  static func sorted(_ cards: [CreditCard], now: Date, calendar: Calendar) -> [CreditCard] {
    cards.map { (card: $0, due: $0.nextDueDate(now: now, calendar: calendar)) }
      .sorted { ($0.due, $0.card.name) < ($1.due, $1.card.name) }
      .map(\.card)
  }

  private static func date(day: Int, inMonthStarting month: Date, calendar: Calendar) -> Date {
    let days = calendar.range(of: .day, in: .month, for: month)!.count
    return calendar.date(byAdding: .day, value: min(day, days) - 1, to: month)!
  }
}

extension CreditCard {
  func nextDueDate(now: Date, calendar: Calendar) -> Date {
    CreditCardDates.next(day: dueDay, onOrAfter: now, calendar: calendar)
  }

  func isStatementBalanceStale(now: Date, calendar: Calendar) -> Bool {
    CreditCardDates.isStale(
      updatedAt: statementBalanceUpdatedAt,
      source: statementBalanceSource,
      statementDay: statementDay,
      now: now,
      calendar: calendar
    )
  }

  func isCurrentBalanceStale(now: Date, calendar: Calendar) -> Bool {
    CreditCardDates.isStale(
      updatedAt: currentBalanceUpdatedAt,
      source: currentBalanceSource,
      statementDay: statementDay,
      now: now,
      calendar: calendar
    )
  }

  /// Whether either balance that has been entered is stale.
  func hasStaleBalance(now: Date, calendar: Calendar) -> Bool {
    (statementBalanceCents != nil && isStatementBalanceStale(now: now, calendar: calendar))
      || (currentBalanceCents != nil && isCurrentBalanceStale(now: now, calendar: calendar))
  }

  /// Overrides the statement balance, even an imported one: it becomes manual as of `now`.
  func setStatementBalance(_ cents: Int?, now: Date) {
    statementBalanceCents = cents
    statementBalanceSource = .manual
    statementBalanceUpdatedAt = now
  }

  /// Overrides the current balance, even an imported one: it becomes manual as of `now`.
  func setCurrentBalance(_ cents: Int?, now: Date) {
    currentBalanceCents = cents
    currentBalanceSource = .manual
    currentBalanceUpdatedAt = now
  }

  /// Logs a payment toward this card. It shows with expenses but never counts as spending.
  @discardableResult
  func logPayment(cents: Int, date: Date, in context: ModelContext, now: Date) throws -> Expense {
    try CategoryService(context: context).createExpense(
      amountCents: cents,
      note: name,
      date: date,
      now: now,
      isCardPayment: true,
      creditCard: self
    )
  }
}

/// The card editor's fields. Balances may be blank, but not negative.
struct CreditCardDraft: Equatable {
  var name = ""
  var statementDay = 1
  var dueDay = 1
  var autopay = false
  var statementBalanceText = ""
  var currentBalanceText = ""
  var locale = Locale.autoupdatingCurrent

  init(card: CreditCard? = nil, locale: Locale = .autoupdatingCurrent) {
    self.locale = locale
    guard let card else { return }
    name = card.name
    statementDay = card.statementDay
    dueDay = card.dueDay
    autopay = card.autopay
    statementBalanceText = card.statementBalanceCents.map(BudgetDraft.text(fromCents:)) ?? ""
    currentBalanceText = card.currentBalanceCents.map(BudgetDraft.text(fromCents:)) ?? ""
  }

  var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

  var statementBalance: BudgetDraft.ParsedAmount {
    BudgetDraft.parseAmount(statementBalanceText, locale: locale)
  }

  var currentBalance: BudgetDraft.ParsedAmount {
    BudgetDraft.parseAmount(currentBalanceText, locale: locale)
  }

  var canSave: Bool {
    !trimmedName.isEmpty && (1...31).contains(statementDay) && (1...31).contains(dueDay)
      && statementBalance.issue == nil && currentBalance.issue == nil
  }

  /// Inserts a new card, or updates `card`. Only a balance that changed is overridden, so editing
  /// the name doesn't make an old balance look fresh. Returns `nil` without changes if invalid.
  @discardableResult
  func save(to card: CreditCard?, in context: ModelContext, now: Date) -> CreditCard? {
    guard canSave else { return nil }
    let saved = card ?? CreditCard(name: trimmedName, statementDay: statementDay, dueDay: dueDay)
    if card == nil {
      context.insert(saved)
    }
    saved.name = trimmedName
    saved.statementDay = statementDay
    saved.dueDay = dueDay
    saved.autopay = autopay
    if statementBalance.amountCents != saved.statementBalanceCents {
      saved.setStatementBalance(statementBalance.amountCents, now: now)
    }
    if currentBalance.amountCents != saved.currentBalanceCents {
      saved.setCurrentBalance(currentBalance.amountCents, now: now)
    }
    return saved
  }
}

extension BudgetDraft.ParsedAmount {
  /// The amount, or `nil` when blank or invalid.
  var amountCents: Int? {
    guard case .cents(let cents) = self else { return nil }
    return cents
  }

  var issue: BudgetDraft.Issue? {
    guard case .failure(let issue) = self else { return nil }
    return issue
  }
}
