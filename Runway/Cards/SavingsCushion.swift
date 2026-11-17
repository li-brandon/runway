import Foundation
import SwiftData

/// A card payment the savings cushion covers: the card's statement balance, due on its next due
/// date.
struct CushionPayment: Equatable, Sendable {
  var name: String
  var amountCents: Int
  var dueDate: Date
}

/// An account's role and balance, as the savings cushion counts it.
struct CushionAccount: Equatable, Sendable {
  var role: CashAccountRole
  var balanceCents: Int?
}

/// How much checking needs for upcoming card payments, and what to move there from savings.
/// Pure value logic in integer cents.
///
/// - **Payments** are every card with a positive statement balance, due on its next due
///   date, soonest first (then by name). Cards with no or a zero balance are left out.
/// - **Cushion** = the payments + the buffer. A blank buffer is 0.
/// - **Checking** and **savings** each sum their accounts' balances. A blank balance
///   counts as 0, an overdrawn one is negative, and `notCounted` accounts are left out.
/// - **Transfer** = cushion − checking, never below 0: what to move from savings to
///   checking. Left to spend today reserves it when `Budget.reservesCushion` is on.
/// - **Shortfall** = transfer − savings, never below 0: what savings can't cover.
/// - **Transfer by** is the due date of the first payment, soonest first, at which the
///   payments so far exceed checking. The buffer counts as needed by the first payment, so
///   a buffer larger than checking makes the first due date the deadline. `nil` when
///   checking covers everything, or when there are no payments: a buffer on its own has no
///   due date.
struct SavingsCushion: Equatable, Sendable {
  /// Soonest due first, then by name.
  let payments: [CushionPayment]
  let bufferCents: Int
  let checkingCents: Int
  let savingsCents: Int

  init(payments: [CushionPayment], bufferCents: Int?, accounts: [CushionAccount]) {
    self.payments = payments.filter { $0.amountCents > 0 }
      .sorted { ($0.dueDate, $0.name) < ($1.dueDate, $1.name) }
    self.bufferCents = max(0, bufferCents ?? 0)
    func total(_ role: CashAccountRole) -> Int {
      accounts.filter { $0.role == role }.reduce(0) { $0 + ($1.balanceCents ?? 0) }
    }
    checkingCents = total(.checking)
    savingsCents = total(.savings)
  }

  var paymentsCents: Int {
    payments.reduce(0) { $0 + $1.amountCents }
  }

  var cushionCents: Int {
    paymentsCents + bufferCents
  }

  var transferCents: Int {
    max(0, cushionCents - checkingCents)
  }

  var shortfallCents: Int {
    max(0, transferCents - savingsCents)
  }

  var transferBy: Date? {
    var neededCents = bufferCents
    for payment in payments {
      neededCents += payment.amountCents
      if neededCents > checkingCents { return payment.dueDate }
    }
    return nil
  }

  /// Whether the transfer is due before `payday`, so it can't wait for the next paycheck.
  func isTransferDue(before payday: Date) -> Bool {
    transferBy.map { $0 < payday } ?? false
  }
}

extension SavingsCushion {
  /// The cushion for `cards` and `accounts`, with `budget`'s buffer if there is a budget.
  init(
    budget: Budget?,
    cards: [CreditCard],
    accounts: [CashAccount],
    now: Date,
    calendar: Calendar
  ) {
    self.init(
      payments: CardPayoffSchedule(cards: cards, now: now, nextPayday: nil, calendar: calendar)
        .payments.map {
          CushionPayment(name: $0.name, amountCents: $0.amountCents, dueDate: $0.dueDate)
        },
      bufferCents: budget?.cushionBufferCents,
      accounts: accounts.map { CushionAccount(role: $0.role, balanceCents: $0.balanceCents) }
    )
  }
}

extension Budget {
  /// What Left to spend today holds back for the savings cushion: its transfer while
  /// `reservesCushion` is on, otherwise 0.
  func cushionReserveCents(
    cards: [CreditCard],
    accounts: [CashAccount],
    now: Date,
    calendar: Calendar
  ) -> Int {
    guard reservesCushion else { return 0 }
    let cushion = SavingsCushion(
      budget: self,
      cards: cards,
      accounts: accounts,
      now: now,
      calendar: calendar
    )
    return cushion.transferCents
  }
}

extension CashAccount {
  /// Overrides the balance, even an imported one: it becomes manual as of `now`.
  func setBalance(_ cents: Int?, now: Date) {
    balanceCents = cents
    balanceSource = .manual
    balanceUpdatedAt = now
  }
}

extension CashAccountRole {
  var title: String {
    switch self {
    case .checking: "Checking"
    case .savings: "Savings"
    case .notCounted: "Not counted"
    }
  }
}

/// The account editor's fields. The balance may be blank, or negative for an overdrawn account.
struct CashAccountDraft: Equatable {
  var name = ""
  var role = CashAccountRole.checking
  var balanceText = ""
  var locale = Locale.autoupdatingCurrent

  init(account: CashAccount? = nil, locale: Locale = .autoupdatingCurrent) {
    self.locale = locale
    guard let account else { return }
    name = account.name
    role = account.role
    balanceText = account.balanceCents.map(BudgetDraft.text(fromCents:)) ?? ""
  }

  var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

  var balance: BudgetDraft.ParsedAmount {
    BudgetDraft.parseAmount(balanceText, locale: locale, allowsNegative: true)
  }

  var canSave: Bool {
    !trimmedName.isEmpty && balance.issue == nil
  }

  /// Inserts a new account, or updates `account`. Only a changed balance is overridden, so editing
  /// the name doesn't make an old balance look fresh. Returns `nil` without changes if invalid.
  @discardableResult
  func save(to account: CashAccount?, in context: ModelContext, now: Date) -> CashAccount? {
    guard canSave else { return nil }
    let saved = account ?? CashAccount(name: trimmedName, role: role)
    if account == nil {
      context.insert(saved)
    }
    saved.name = trimmedName
    saved.role = role
    if balance.amountCents != saved.balanceCents {
      saved.setBalance(balance.amountCents, now: now)
    }
    return saved
  }
}

/// The cushion settings editor's fields: the buffer, which may be blank, and the daily reserve.
struct CushionSettingsDraft: Equatable {
  var bufferText = ""
  var reservesCushion = false
  var locale = Locale.autoupdatingCurrent

  init(budget: Budget? = nil, locale: Locale = .autoupdatingCurrent) {
    self.locale = locale
    guard let budget else { return }
    bufferText = budget.cushionBufferCents.map(BudgetDraft.text(fromCents:)) ?? ""
    reservesCushion = budget.reservesCushion
  }

  var buffer: BudgetDraft.ParsedAmount {
    BudgetDraft.parseAmount(bufferText, locale: locale)
  }

  var canSave: Bool {
    buffer.issue == nil
  }

  /// Updates `budget`. A blank or zero buffer is stored as none. Returns whether it was valid.
  @discardableResult
  func save(to budget: Budget) -> Bool {
    guard canSave else { return false }
    budget.cushionBufferCents = buffer.amountCents.flatMap { $0 > 0 ? $0 : nil }
    budget.reservesCushion = reservesCushion
    return true
  }
}
