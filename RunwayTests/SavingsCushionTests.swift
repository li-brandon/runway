import Foundation
import SwiftData
import Testing

@testable import Runway

/// Savings cushion transfer math, accounts and settings, and the reserve in Left to spend today.
struct SavingsCushionTests {
  let calendar = Calendar.gregorian("America/Chicago")

  private func makeContext() throws -> ModelContext {
    ModelContext(try RunwayModelContainer.make(inMemory: true))
  }

  private func payment(_ name: String, _ cents: Int, due day: Int) -> CushionPayment {
    CushionPayment(name: name, amountCents: cents, dueDate: calendar.date(2026, 6, day))
  }

  private func checking(_ cents: Int?) -> CushionAccount {
    CushionAccount(role: .checking, balanceCents: cents)
  }

  private func savings(_ cents: Int?) -> CushionAccount {
    CushionAccount(role: .savings, balanceCents: cents)
  }

  // MARK: - Transfer math

  @Test("When checking already covers everything, nothing moves and there's no date")
  func checkingCoversEverything() {
    let cushion = SavingsCushion(
      payments: [payment("Visa", 30_000, due: 15), payment("Amex", 20_000, due: 25)],
      bufferCents: nil,
      accounts: [checking(60_000), savings(100_000)]
    )
    #expect(cushion.cushionCents == 50_000)
    #expect(cushion.transferCents == 0)
    #expect(cushion.shortfallCents == 0)
    #expect(cushion.transferBy == nil)

    // Exactly covered is still covered.
    let exact = SavingsCushion(
      payments: [payment("Visa", 30_000, due: 15), payment("Amex", 20_000, due: 25)],
      bufferCents: 10_000,
      accounts: [checking(60_000)]
    )
    #expect(exact.transferCents == 0 && exact.transferBy == nil)
  }

  @Test("The transfer is due by the first payment checking can't cover")
  func transferByDate() {
    let payments = [payment("Visa", 30_000, due: 15), payment("Amex", 40_000, due: 25)]
    let cushion = SavingsCushion(
      payments: payments,
      bufferCents: nil,
      accounts: [checking(50_000), savings(100_000)]
    )
    #expect(cushion.cushionCents == 70_000)
    #expect(cushion.transferCents == 20_000)
    #expect(cushion.shortfallCents == 0)
    // Visa fits in checking; Visa and Amex together don't.
    #expect(cushion.transferBy == calendar.date(2026, 6, 25))

    // Checking can't cover even the first payment.
    let short = SavingsCushion(
      payments: payments,
      bufferCents: nil,
      accounts: [checking(10_000), savings(100_000)]
    )
    #expect(short.transferCents == 60_000)
    #expect(short.transferBy == calendar.date(2026, 6, 15))
  }

  @Test("A buffer adds to the cushion and counts as needed by the first payment")
  func buffer() {
    let payments = [payment("Visa", 30_000, due: 15), payment("Amex", 40_000, due: 25)]
    let cushion = SavingsCushion(
      payments: payments,
      bufferCents: 25_000,
      accounts: [checking(60_000)]
    )
    #expect(cushion.bufferCents == 25_000)
    #expect(cushion.paymentsCents == 70_000)
    #expect(cushion.cushionCents == 95_000)
    #expect(cushion.transferCents == 35_000)
    // 25,000 + 30,000 fits in 60,000; adding Amex doesn't.
    #expect(cushion.transferBy == calendar.date(2026, 6, 25))

    // A buffer bigger than checking makes the first payment the deadline.
    let bigBuffer = SavingsCushion(
      payments: payments,
      bufferCents: 70_000,
      accounts: [checking(60_000)]
    )
    #expect(bigBuffer.transferBy == calendar.date(2026, 6, 15))

    // A negative buffer counts as none.
    let negative = SavingsCushion(payments: payments, bufferCents: -5, accounts: [])
    #expect(negative.bufferCents == 0 && negative.cushionCents == 70_000)
  }

  @Test("With no cards there's nothing to cover, except a buffer, which has no due date")
  func noCards() {
    let empty = SavingsCushion(payments: [], bufferCents: nil, accounts: [checking(5_000)])
    #expect(empty.cushionCents == 0)
    #expect(empty.transferCents == 0)
    #expect(empty.transferBy == nil)

    let bufferOnly = SavingsCushion(
      payments: [],
      bufferCents: 20_000,
      accounts: [checking(5_000), savings(10_000)]
    )
    #expect(bufferOnly.cushionCents == 20_000)
    #expect(bufferOnly.transferCents == 15_000)
    #expect(bufferOnly.shortfallCents == 5_000)
    #expect(bufferOnly.transferBy == nil)
  }

  @Test("Cards with no or a zero statement balance aren't payments")
  func ignoresBlankAndZeroBalances() {
    let now = calendar.date(2026, 6, 10, 12)
    let blank = CreditCard(name: "Blank", statementDay: 1, dueDay: 12)
    let zero = CreditCard(name: "Zero", statementDay: 1, dueDay: 13)
    zero.setStatementBalance(0, now: now)
    let owed = CreditCard(name: "Owed", statementDay: 1, dueDay: 20)
    owed.setStatementBalance(45_000, now: now)
    // A current balance alone isn't a payment due.
    blank.setCurrentBalance(99_000, now: now)

    let cushion = SavingsCushion(
      budget: nil,
      cards: [blank, zero, owed],
      accounts: [],
      now: now,
      calendar: calendar
    )
    #expect(cushion.payments.map(\.name) == ["Owed"])
    #expect(cushion.payments.map(\.dueDate) == [calendar.date(2026, 6, 20)])
    #expect(cushion.cushionCents == 45_000)
    #expect(cushion.transferBy == calendar.date(2026, 6, 20))

    // Zero-amount payments passed in directly are dropped too.
    let direct = SavingsCushion(
      payments: [payment("Zero", 0, due: 11), payment("Visa", 100, due: 12)],
      bufferCents: nil,
      accounts: []
    )
    #expect(direct.payments.map(\.name) == ["Visa"])
  }

  @Test("An account with no balance counts as zero")
  func blankAccountBalance() {
    let cushion = SavingsCushion(
      payments: [payment("Visa", 30_000, due: 15)],
      bufferCents: nil,
      accounts: [checking(nil), savings(nil)]
    )
    #expect(cushion.checkingCents == 0 && cushion.savingsCents == 0)
    #expect(cushion.transferCents == 30_000)
    #expect(cushion.shortfallCents == 30_000)
    #expect(cushion.transferBy == calendar.date(2026, 6, 15))
  }

  @Test("An overdrawn checking account adds its overdraft to the transfer")
  func overdrawnChecking() {
    let cushion = SavingsCushion(
      payments: [payment("Visa", 50_000, due: 15)],
      bufferCents: nil,
      accounts: [checking(-20_000), savings(100_000)]
    )
    #expect(cushion.checkingCents == -20_000)
    #expect(cushion.transferCents == 70_000)
    #expect(cushion.shortfallCents == 0)
    #expect(cushion.transferBy == calendar.date(2026, 6, 15))
  }

  @Test("Checking and savings each sum their accounts; uncounted accounts are left out")
  func sumsAccounts() {
    let cushion = SavingsCushion(
      payments: [payment("Visa", 100_000, due: 15)],
      bufferCents: nil,
      accounts: [
        checking(20_000), checking(15_000), savings(30_000), savings(nil), savings(25_000),
        CushionAccount(role: .notCounted, balanceCents: 1_000_000),
      ]
    )
    #expect(cushion.checkingCents == 35_000)
    #expect(cushion.savingsCents == 55_000)
    #expect(cushion.transferCents == 65_000)
    #expect(cushion.shortfallCents == 10_000)
  }

  @Test("Savings short of the transfer leaves a shortfall")
  func shortfall() {
    let payments = [payment("Visa", 50_000, due: 15), payment("Amex", 20_000, due: 25)]
    let covered = SavingsCushion(
      payments: payments,
      bufferCents: nil,
      accounts: [checking(10_000), savings(60_000)]
    )
    #expect(covered.transferCents == 60_000 && covered.shortfallCents == 0)

    let short = SavingsCushion(
      payments: payments,
      bufferCents: nil,
      accounts: [checking(10_000), savings(45_000)]
    )
    #expect(short.transferCents == 60_000)
    #expect(short.shortfallCents == 15_000)
  }

  @Test("Payments are ordered by next due date across a month end, not by due day")
  func dueDateOrderAcrossMonthEnd() {
    let now = calendar.date(2026, 6, 28, 12)
    let early = CreditCard(name: "Early", statementDay: 10, dueDay: 2)
    early.setStatementBalance(10_000, now: now)
    let late = CreditCard(name: "Late", statementDay: 10, dueDay: 30)
    late.setStatementBalance(10_000, now: now)
    // The 31st falls on June 30, the same day as Late, so the name breaks the tie.
    let monthEnd = CreditCard(name: "Month End", statementDay: 10, dueDay: 31)
    monthEnd.setStatementBalance(5_000, now: now)
    let account = CashAccount(name: "Checking", role: .checking)
    account.setBalance(20_000, now: now)

    let cushion = SavingsCushion(
      budget: nil,
      cards: [early, late, monthEnd],
      accounts: [account],
      now: now,
      calendar: calendar
    )
    #expect(cushion.payments.map(\.name) == ["Late", "Month End", "Early"])
    #expect(
      cushion.payments.map(\.dueDate) == [
        calendar.date(2026, 6, 30), calendar.date(2026, 6, 30), calendar.date(2026, 7, 2),
      ]
    )
    #expect(cushion.transferCents == 5_000)
    // June's two payments fit in checking; Early, due in July, doesn't.
    #expect(cushion.transferBy == calendar.date(2026, 7, 2))
  }

  @Test("The next payday is the next period's start, or the first one before the budget starts")
  func nextPayday() {
    let budget = BudgetSnapshot(
      periodLength: .biweekly,
      periodStart: calendar.date(2026, 6, 7),
      spendablePerPeriodCents: 140_000
    )
    let now = calendar.date(2026, 6, 10, 12)
    let payday = CardPayoffSchedule.nextPayday(after: now, of: budget, calendar: calendar)
    #expect(payday == calendar.date(2026, 6, 21))
    let early = CardPayoffSchedule.nextPayday(
      after: calendar.date(2026, 6, 1),
      of: budget,
      calendar: calendar
    )
    #expect(early == calendar.date(2026, 6, 7))

    let cushion = SavingsCushion(
      payments: [payment("Visa", 30_000, due: 15), payment("Amex", 40_000, due: 25)],
      bufferCents: nil,
      accounts: [checking(50_000)]
    )
    // Due June 25, after the June 21 payday.
    #expect(!cushion.isTransferDue(before: payday))
    #expect(cushion.isTransferDue(before: calendar.date(2026, 6, 26)))
    let covered = SavingsCushion(payments: [], bufferCents: nil, accounts: [])
    #expect(!covered.isTransferDue(before: payday))
  }

  // MARK: - Daily reserve

  private let budget = BudgetSnapshot(
    periodLength: .biweekly,
    periodStart: Calendar.gregorian("America/Chicago").date(2026, 6, 7),
    spendablePerPeriodCents: 140_000
  )

  private func allowance(
    reserveCents: Int? = nil,
    expenses: [ExpenseSnapshot] = []
  ) -> AllowanceResult {
    let engine = AllowanceEngine(calendar: calendar)
    let now = calendar.date(2026, 6, 10, 12)
    guard let reserveCents else {
      return engine.currentAllowance(budget: budget, expenses: expenses, now: now)
    }
    return engine.currentAllowance(
      budget: budget,
      expenses: expenses,
      now: now,
      reserveCents: reserveCents
    )
  }

  @Test("Off by default: no reserve leaves every figure as it was")
  func reserveOff() {
    let plain = allowance()
    #expect(allowance(reserveCents: 0) == plain)
    #expect(plain.reservedCents == 0)
    // 140,000 over the 11 days left, June 10–20.
    #expect(plain.daysLeft == 11)
    #expect(plain.allowanceTodayCents == 12_727)
    #expect(plain.remainingPeriodCents == 140_000)
    // A negative reserve counts as none.
    #expect(allowance(reserveCents: -5_000) == plain)
  }

  @Test("A reserve comes off the period's money before it's divided into days")
  func reserveOn() {
    let result = allowance(reserveCents: 30_800)
    #expect(result.reservedCents == 30_800)
    // (140,000 − 30,800) ÷ 11 = 9,927.27…, floored.
    #expect(result.allowanceTodayCents == 9_927)
    #expect(result.remainingTodayCents == 9_927)
    #expect(result.remainingPeriodCents == 109_200)
    #expect(!result.isOverBudget)
    #expect(TodayStatus(result) == .normal)
  }

  @Test("A reserve larger than the money left takes only what's there and never goes over")
  func reserveLargerThanRemaining() {
    let spent = [ExpenseSnapshot(amountCents: 100_000, date: calendar.date(2026, 6, 8, 12))]
    let result = allowance(reserveCents: 500_000, expenses: spent)
    #expect(result.reservedCents == 40_000)
    #expect(result.allowanceTodayCents == 0)
    #expect(result.remainingPeriodCents == 0)
    #expect(!result.isOverBudget)
    #expect(TodayStatus(result) == .noAllowance)

    // Spending today still shows as over.
    let today = spent + [ExpenseSnapshot(amountCents: 1_000, date: calendar.date(2026, 6, 10, 9))]
    let over = allowance(reserveCents: 500_000, expenses: today)
    #expect(over.remainingTodayCents == -1_000)
    #expect(over.isOverBudget)

    // Already overspent: there's nothing to reserve, so the figures don't change.
    let overspent = [ExpenseSnapshot(amountCents: 150_000, date: calendar.date(2026, 6, 8, 12))]
    let unreserved = allowance(expenses: overspent)
    let reserved = allowance(reserveCents: 20_000, expenses: overspent)
    #expect(reserved.reservedCents == 0)
    #expect(reserved == unreserved)
  }

  @Test("The budget reserves the cushion's transfer only while the setting is on")
  func budgetReserve() throws {
    let context = try makeContext()
    let now = calendar.date(2026, 6, 10, 12)
    let budget = Budget(
      periodStart: calendar.date(2026, 6, 7),
      spendablePerPeriodCents: 140_000,
      timeZoneIdentifier: calendar.timeZone.identifier,
      cushionBufferCents: 10_000
    )
    context.insert(budget)
    let card = CreditCard(name: "Visa", statementDay: 1, dueDay: 25)
    context.insert(card)
    card.setStatementBalance(50_000, now: now)
    let account = CashAccount(name: "Checking", role: .checking)
    context.insert(account)
    account.setBalance(29_200, now: now)
    try context.save()

    let cards = try context.fetch(FetchDescriptor<CreditCard>())
    let accounts = try context.fetch(FetchDescriptor<CashAccount>())
    func reserve() -> Int {
      budget.cushionReserveCents(cards: cards, accounts: accounts, now: now, calendar: calendar)
    }
    #expect(reserve() == 0)
    budget.reservesCushion = true
    // 50,000 + 10,000 buffer − 29,200 in checking.
    #expect(reserve() == 30_800)

    let result = AllowanceEngine(calendar: calendar).currentAllowance(
      budget: BudgetSnapshot(budget),
      expenses: [],
      now: now,
      reserveCents: reserve()
    )
    #expect(result.allowanceTodayCents == 9_927)

    // Once checking covers the cushion, nothing is reserved.
    account.setBalance(60_000, now: now)
    #expect(reserve() == 0)
  }

  // MARK: - Editing

  @Test("Accounts are added and edited, and only a changed balance is overridden")
  func accountDraft() throws {
    let context = try makeContext()
    let added = calendar.date(2026, 6, 1, 9)
    var draft = CashAccountDraft(locale: Money.fixedLocale)
    #expect(draft.role == .checking)
    draft.name = "  Everyday  "
    draft.balanceText = "$1,250.50"
    #expect(draft.save(to: nil, in: context, now: added) != nil)
    try context.save()

    let loaded = ModelContext(context.container)
    let account = try #require(try loaded.fetch(FetchDescriptor<CashAccount>()).first)
    #expect(account.name == "Everyday" && account.role == .checking)
    #expect(account.balanceCents == 125_050 && account.balanceUpdatedAt == added)
    #expect(account.balanceSource == .manual)

    // Renaming and changing the role keep the balance's date.
    let edited = calendar.date(2026, 6, 10, 9)
    var edit = CashAccountDraft(account: account, locale: Money.fixedLocale)
    edit.name = "Rainy Day"
    edit.role = .savings
    #expect(edit.save(to: account, in: loaded, now: edited) === account)
    #expect(account.role == .savings && account.balanceUpdatedAt == added)

    // An imported balance becomes manual once overridden.
    account.balanceSource = .imported
    var override = CashAccountDraft(account: account, locale: Money.fixedLocale)
    override.balanceText = ""
    override.save(to: account, in: loaded, now: edited)
    #expect(account.balanceCents == nil && account.balanceUpdatedAt == edited)
    #expect(account.balanceSource == .manual)
  }

  @Test("An account needs a name and a valid balance, which may be blank or overdrawn")
  func accountValidation() throws {
    var draft = CashAccountDraft(locale: Money.fixedLocale)
    #expect(!draft.canSave)
    draft.name = "Checking"
    #expect(draft.canSave)
    draft.balanceText = "-$5.25"
    #expect(draft.balance == .cents(-525))
    #expect(draft.canSave)
    // An overdrawn balance reopens in the editor as the same amount.
    let overdrawn = CashAccount(name: "Overdrawn", role: .checking)
    overdrawn.setBalance(-525, now: .now)
    #expect(CashAccountDraft(account: overdrawn, locale: Money.fixedLocale).balance == .cents(-525))
    draft.balanceText = "abc"
    #expect(!draft.canSave)
    draft.balanceText = "0"
    #expect(draft.canSave)

    let context = try makeContext()
    draft.name = " "
    #expect(draft.save(to: nil, in: context, now: .now) == nil)
    #expect(try context.fetchCount(FetchDescriptor<CashAccount>()) == 0)
  }

  @Test("Cushion settings save the buffer, blank or zero as none, and the reserve")
  func settingsDraft() {
    let budget = Budget(periodStart: calendar.date(2026, 6, 7), spendablePerPeriodCents: 1)
    var draft = CushionSettingsDraft(budget: budget, locale: Money.fixedLocale)
    #expect(draft.bufferText.isEmpty && !draft.reservesCushion)

    draft.bufferText = "200"
    draft.reservesCushion = true
    #expect(draft.save(to: budget))
    #expect(budget.cushionBufferCents == 20_000 && budget.reservesCushion)
    let reopened = CushionSettingsDraft(budget: budget, locale: Money.fixedLocale)
    #expect(reopened.buffer == .cents(20_000) && reopened.reservesCushion)

    draft.bufferText = "0"
    #expect(draft.save(to: budget))
    #expect(budget.cushionBufferCents == nil)
    draft.bufferText = ""
    #expect(draft.save(to: budget))
    #expect(budget.cushionBufferCents == nil)

    draft.bufferText = "-1"
    draft.reservesCushion = false
    #expect(!draft.canSave)
    #expect(!draft.save(to: budget))
    #expect(budget.reservesCushion)
  }
}
