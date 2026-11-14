import Foundation
import SwiftData
import Testing

@testable import Runway

/// Credit card dates, stale balances, overrides, persistence, and payments that aren't spending.
struct CreditCardTests {
  let calendar = Calendar.gregorian("America/Chicago")

  private func makeContext() throws -> ModelContext {
    ModelContext(try RunwayModelContainer.make(inMemory: true))
  }

  // MARK: - Dates

  @Test("The next due date is today or later, clamped to the month's last day")
  func nextDueDate() {
    func next(_ day: Int, _ now: Date) -> Date {
      CreditCardDates.next(day: day, onOrAfter: now, calendar: calendar)
    }
    // Due today, even late in the day.
    #expect(next(10, calendar.date(2026, 6, 10, 23)) == calendar.date(2026, 6, 10))
    // Later this month.
    #expect(next(25, calendar.date(2026, 6, 10, 12)) == calendar.date(2026, 6, 25))
    // Already passed this month, so it wraps to next month, and into next year.
    #expect(next(5, calendar.date(2026, 6, 10, 12)) == calendar.date(2026, 7, 5))
    #expect(next(3, calendar.date(2026, 12, 20)) == calendar.date(2027, 1, 3))
    // The 29th–31st fall on the last day of shorter months.
    #expect(next(31, calendar.date(2026, 2, 10)) == calendar.date(2026, 2, 28))
    #expect(next(31, calendar.date(2028, 2, 10)) == calendar.date(2028, 2, 29))
    #expect(next(31, calendar.date(2026, 4, 30, 12)) == calendar.date(2026, 4, 30))
    #expect(next(30, calendar.date(2026, 2, 28, 12)) == calendar.date(2026, 2, 28))
    // Wrapping after a clamp goes back to the card's own day.
    #expect(next(29, calendar.date(2026, 3, 30)) == calendar.date(2026, 4, 29))
  }

  @Test("Days left counts whole days from the start of today")
  func daysLeft() {
    func daysLeft(_ due: Date, _ now: Date) -> Int {
      CreditCardDates.daysLeft(until: due, now: now, calendar: calendar)
    }
    #expect(daysLeft(calendar.date(2026, 6, 10), calendar.date(2026, 6, 10, 23)) == 0)
    #expect(daysLeft(calendar.date(2026, 6, 11), calendar.date(2026, 6, 10, 23)) == 1)
    #expect(daysLeft(calendar.date(2026, 7, 5), calendar.date(2026, 6, 10, 1)) == 25)
    // Across the March DST change.
    #expect(daysLeft(calendar.date(2026, 3, 10), calendar.date(2026, 3, 7, 12)) == 3)
  }

  // MARK: - Stale balances

  private func isStale(
    _ updatedAt: Date?,
    _ source: CardBalanceSource,
    statementDay: Int = 15,
    now: Date
  ) -> Bool {
    CreditCardDates.isStale(
      updatedAt: updatedAt,
      source: source,
      statementDay: statementDay,
      now: now,
      calendar: calendar
    )
  }

  @Test("A balance that was never entered is stale")
  func missingIsStale() {
    let now = calendar.date(2026, 6, 10)
    #expect(isStale(nil, .manual, now: now))
    #expect(isStale(nil, .imported, now: now))
  }

  @Test("A manual balance is stale once the next statement day after its entry begins")
  func manualCycle() {
    let before = calendar.date(2026, 6, 14, 20)
    #expect(!isStale(before, .manual, now: calendar.date(2026, 6, 14, 23, 59)))
    #expect(isStale(before, .manual, now: calendar.date(2026, 6, 15)))

    // Entered on statement day: fresh until the following statement day.
    let onStatementDay = calendar.date(2026, 6, 15, 9)
    #expect(!isStale(onStatementDay, .manual, now: calendar.date(2026, 6, 15, 23)))
    #expect(!isStale(onStatementDay, .manual, now: calendar.date(2026, 7, 14, 23, 59)))
    #expect(isStale(onStatementDay, .manual, now: calendar.date(2026, 7, 15)))

    // A 31st statement day closes on February's last day.
    let january = calendar.date(2026, 1, 31, 12)
    #expect(!isStale(january, .manual, statementDay: 31, now: calendar.date(2026, 2, 27, 23)))
    #expect(isStale(january, .manual, statementDay: 31, now: calendar.date(2026, 2, 28)))
  }

  @Test("An imported balance is stale after 24 hours, whatever the statement day")
  func importedDay() {
    let updated = calendar.date(2026, 6, 14, 20)
    let dayLater = updated.addingTimeInterval(24 * 60 * 60)
    #expect(!isStale(updated, .imported, now: dayLater.addingTimeInterval(-1)))
    #expect(isStale(updated, .imported, now: dayLater))
    // A manual balance would still be fresh then.
    #expect(!isStale(updated, .manual, statementDay: 20, now: dayLater))
  }

  @Test("Overriding an imported balance makes it manual and fresh as of now")
  func overrideImported() {
    let card = CreditCard(name: "Visa", statementDay: 15, dueDay: 5)
    card.statementBalanceCents = 10_000
    card.statementBalanceSource = .imported
    card.statementBalanceUpdatedAt = calendar.date(2026, 6, 8)
    card.currentBalanceCents = 20_000
    card.currentBalanceSource = .imported
    card.currentBalanceUpdatedAt = calendar.date(2026, 6, 8)
    let now = calendar.date(2026, 6, 10, 12)
    #expect(card.isStatementBalanceStale(now: now, calendar: calendar))
    #expect(card.isCurrentBalanceStale(now: now, calendar: calendar))
    #expect(card.hasStaleBalance(now: now, calendar: calendar))

    card.setStatementBalance(12_000, now: now)
    card.setCurrentBalance(20_000, now: now)
    #expect(card.statementBalanceCents == 12_000)
    #expect(card.statementBalanceSource == .manual && card.currentBalanceSource == .manual)
    #expect(card.statementBalanceUpdatedAt == now && card.currentBalanceUpdatedAt == now)
    let twoDaysLater = now.addingTimeInterval(2 * 24 * 60 * 60)
    #expect(!card.hasStaleBalance(now: twoDaysLater, calendar: calendar))
  }

  @Test("Only entered balances can make a card stale")
  func staleIgnoresBlankBalances() {
    let card = CreditCard(name: "Visa", statementDay: 15, dueDay: 5)
    let now = calendar.date(2026, 6, 10, 12)
    #expect(!card.hasStaleBalance(now: now, calendar: calendar))
    card.setCurrentBalance(5_000, now: calendar.date(2026, 5, 1))
    #expect(card.hasStaleBalance(now: now, calendar: calendar))
  }

  // MARK: - Persistence

  @Test("Cards are added, edited, and removed, and only changed balances are overridden")
  func addEditRemove() throws {
    let context = try makeContext()
    let added = calendar.date(2026, 6, 1, 9)
    var draft = CreditCardDraft(locale: Money.fixedLocale)
    draft.name = "  Visa  "
    draft.statementDay = 28
    draft.dueDay = 31
    draft.autopay = true
    draft.statementBalanceText = "$842.15"
    #expect(draft.save(to: nil, in: context, now: added) != nil)
    try context.save()

    let loaded = ModelContext(context.container)
    let card = try #require(try loaded.fetch(FetchDescriptor<CreditCard>()).first)
    #expect(card.name == "Visa" && card.statementDay == 28 && card.dueDay == 31 && card.autopay)
    #expect(card.statementBalanceCents == 84_215 && card.statementBalanceUpdatedAt == added)
    #expect(card.currentBalanceCents == nil && card.currentBalanceUpdatedAt == nil)

    // Renaming keeps the balance's date; a new current balance gets today's.
    let edited = calendar.date(2026, 6, 10, 9)
    var edit = CreditCardDraft(card: card, locale: Money.fixedLocale)
    edit.name = "Travel Visa"
    edit.autopay = false
    edit.currentBalanceText = "1,260.50"
    #expect(edit.save(to: card, in: loaded, now: edited) === card)
    try loaded.save()
    #expect(card.name == "Travel Visa" && !card.autopay)
    #expect(card.statementBalanceUpdatedAt == added)
    #expect(card.currentBalanceCents == 126_050 && card.currentBalanceUpdatedAt == edited)

    // Clearing a balance.
    var clear = CreditCardDraft(card: card, locale: Money.fixedLocale)
    clear.statementBalanceText = ""
    clear.save(to: card, in: loaded, now: edited)
    #expect(card.statementBalanceCents == nil)

    // A logged payment outlives its deleted card and still isn't spending.
    try card.logPayment(cents: 50_000, date: edited, in: loaded, now: edited)
    try loaded.save()
    loaded.delete(card)
    try loaded.save()
    let reloaded = ModelContext(context.container)
    #expect(try reloaded.fetchCount(FetchDescriptor<CreditCard>()) == 0)
    let payment = try #require(try reloaded.fetch(FetchDescriptor<Expense>()).first)
    #expect(payment.isCardPayment && payment.creditCard == nil)
    #expect(payment.category?.isSystem == true)
  }

  @Test("A card needs a name, real days, and balances that are blank or not negative")
  func validation() throws {
    var draft = CreditCardDraft(locale: Money.fixedLocale)
    draft.name = "Visa"
    #expect(draft.canSave)
    draft.name = "   "
    #expect(!draft.canSave)
    draft.name = "Visa"
    draft.dueDay = 32
    #expect(!draft.canSave)
    draft.dueDay = 1
    draft.statementDay = 0
    #expect(!draft.canSave)
    draft.statementDay = 1
    draft.statementBalanceText = "-5"
    #expect(draft.statementBalance.issue == .negative)
    #expect(!draft.canSave)
    draft.statementBalanceText = "0"
    draft.currentBalanceText = "abc"
    #expect(!draft.canSave)
    draft.currentBalanceText = ""
    #expect(draft.canSave)

    let context = try makeContext()
    draft.name = ""
    #expect(draft.save(to: nil, in: context, now: .now) == nil)
    #expect(try context.fetchCount(FetchDescriptor<CreditCard>()) == 0)
  }

  @Test("The list sorts by next due date, then name")
  func sortOrder() {
    let now = calendar.date(2026, 6, 10, 12)
    let cards = [
      CreditCard(name: "Wrapped", statementDay: 1, dueDay: 5),
      CreditCard(name: "Today B", statementDay: 1, dueDay: 10),
      CreditCard(name: "Month end", statementDay: 1, dueDay: 31),
      CreditCard(name: "Today A", statementDay: 1, dueDay: 10),
    ]
    let sorted = CreditCardDates.sorted(cards, now: now, calendar: calendar)
    #expect(sorted.map(\.name) == ["Today A", "Today B", "Month end", "Wrapped"])
  }

  // MARK: - Payments aren't spending

  @Test("A card payment changes no allowance, history, or summary figure; a purchase does")
  func paymentsAreNotSpending() throws {
    let context = try makeContext()
    let now = calendar.date(2026, 6, 10, 12)
    let budget = Budget(
      periodStart: calendar.date(2026, 6, 7),
      spendablePerPeriodCents: 140_000,
      timeZoneIdentifier: calendar.timeZone.identifier
    )
    context.insert(budget)
    let card = CreditCard(name: "Visa", statementDay: 1, dueDay: 25)
    context.insert(card)
    let service = CategoryService(context: context)
    try service.seed()

    func figures() throws -> [Int] {
      let expenses = try context.fetch(FetchDescriptor<Expense>())
      let snapshot = BudgetSnapshot(budget)
      let allowance = AllowanceEngine(calendar: calendar).currentAllowance(
        budget: snapshot,
        expenses: expenses.map { ExpenseSnapshot($0) },
        now: now
      )
      let history = expenses.map { HistoryExpense<PersistentIdentifier?>($0) }
      let period = try #require(
        HistoryEngine(calendar: calendar).periods(budget: snapshot, expenses: history, now: now)
          .first
      )
      let summary = SpendingSummaryEngine(calendar: calendar).summary(
        budget: snapshot,
        expenses: history,
        view: .week,
        mode: .rolling,
        now: now
      )
      return [
        allowance.spentTodayCents, allowance.allowanceTodayCents, allowance.remainingPeriodCents,
        period.spentCents, period.categories.count, summary.spentCents,
      ]
    }

    let empty = try figures()
    try card.logPayment(cents: 50_000, date: calendar.date(2026, 6, 8, 9), in: context, now: now)
    try card.logPayment(cents: 25_000, date: calendar.date(2026, 6, 10, 9), in: context, now: now)
    #expect(try figures() == empty)

    try service.createExpense(amountCents: 2_500, date: calendar.date(2026, 6, 10, 10), now: now)
    let purchased = try figures()
    #expect(purchased[0] == 2_500)
    #expect(purchased[2] == empty[2] - 2_500)
    #expect(purchased[3] == 2_500 && purchased[4] == 1 && purchased[5] == 2_500)
  }

  @Test("Undoing a deleted payment restores it as a payment for the same card")
  func undoKeepsPayment() throws {
    let context = try makeContext()
    let now = calendar.date(2026, 6, 10, 12)
    let card = CreditCard(name: "Visa", statementDay: 1, dueDay: 25)
    context.insert(card)
    let payment = try card.logPayment(cents: 50_000, date: now, in: context, now: now)
    try context.save()

    let deletion = try ExpenseDeletion.delete(payment, in: context, now: now)
    let restored = try #require(try deletion.undo(in: context, now: now))
    #expect(restored.isCardPayment && restored.creditCard === card)
  }
}
