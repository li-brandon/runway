import Foundation
import SwiftData

/// The editable state behind the budget setup screen. Pure value logic, so it's testable without
/// any UI: it parses typed amounts into cents, validates them, computes the live "available this
/// period" figure, and loads from or applies to a `Budget`.
///
/// Decisions:
/// - **Amounts** are typed as text and parsed through `Decimal` into integer cents. `$`, spaces,
///   and valid grouping separators are accepted. `$` amounts infer decimals from the last
///   separator; other input uses the locale's separators.
///   More than two decimal places is rejected rather than rounded. Amounts above
///   `maximumCents` are rejected so sums of cents can't overflow.
/// - **Required:** spendable, and each bill's name and amount. Income and savings are optional
///   and default to none and zero.
/// - **Available** is spendable − bills − savings. While editing, an empty bill amount or savings
///   counts as zero; any invalid amount makes it `nil` (shown as a dash).
/// - **Zero or negative available** shows a warning but can still be saved: a tight period is a
///   real situation, and blocking it would trap a first-launch user on the setup screen. Invalid
///   or missing amounts block saving.
/// - **Bill amounts** are per period, like spendable and savings. The due day is informational.
/// - **Editing a saved budget** never rewrites past days: amounts apply from today, a period
///   length or payday change ends the current period today, and carryover changes wait for the
///   next period. See `apply(to:now:calendar:)`.
struct BudgetDraft: Equatable, Sendable {
  /// One fixed bill row.
  struct Bill: Identifiable, Equatable, Sendable {
    let id: UUID
    /// The saved bill this row edits, or `nil` for a new one.
    var modelID: PersistentIdentifier?
    var name: String
    var amountText: String
    /// Day of the month (1–31), if known.
    var dueDay: Int?

    init(
      id: UUID = UUID(),
      modelID: PersistentIdentifier? = nil,
      name: String = "",
      amountText: String = "",
      dueDay: Int? = nil
    ) {
      self.id = id
      self.modelID = modelID
      self.name = name
      self.amountText = amountText
      self.dueDay = dueDay
    }
  }

  enum Field: Hashable, Sendable {
    case spendable
    case income
    case savings
    case billName(Bill.ID)
    case billAmount(Bill.ID)
  }

  enum Issue: Equatable, Sendable {
    case required
    case invalid
    case negative
    case tooLarge

    var message: String {
      switch self {
      case .required: "Required"
      case .invalid: "Enter a dollar amount, like 12.34"
      case .negative: "Can't be negative"
      case .tooLarge: "Must be \(Money.format(cents: BudgetDraft.maximumCents)) or less"
      }
    }
  }

  enum ParsedAmount: Equatable, Sendable {
    case empty
    case cents(Int)
    case failure(Issue)
  }

  /// $10,000,000.00, the largest amount any field accepts.
  static let maximumCents = 1_000_000_000

  var periodLength: PeriodLength = .biweekly
  /// The payday the first period starts on. Only its local calendar day matters.
  var periodStart: Date
  var spendableText = ""
  var incomeText = ""
  var savingsText = ""
  var bills: [Bill] = []
  var carryoverEnabled = true
  /// Decimal and grouping separators for parsing amounts without a dollar sign.
  var locale: Locale

  /// A new budget's defaults: biweekly, carryover on, everything else empty.
  init(periodStart: Date, locale: Locale = .autoupdatingCurrent) {
    self.periodStart = periodStart
    self.locale = locale
  }

  /// Loads a saved budget. Bills are ordered by due day (none last), then name.
  init(budget: Budget, locale: Locale = .autoupdatingCurrent) {
    self.init(periodStart: budget.periodStart, locale: locale)
    periodLength = budget.periodLength
    spendableText = Self.text(fromCents: budget.spendablePerPeriodCents)
    if let incomeCents = budget.incomeCents {
      incomeText = Self.text(fromCents: incomeCents)
    }
    savingsText = Self.text(fromCents: budget.savingsCents)
    let sortedBills = budget.fixedBills.sorted { lhs, rhs in
      (lhs.dueDay ?? 32, lhs.name) < (rhs.dueDay ?? 32, rhs.name)
    }
    bills = sortedBills.map { bill in
      Bill(
        modelID: bill.persistentModelID,
        name: bill.name,
        amountText: Self.text(fromCents: bill.amountCents),
        dueDay: bill.dueDay
      )
    }
    carryoverEnabled = budget.carryoverEnabled
  }

  // MARK: - Derived values

  /// Problems that block saving, keyed by field. Empty when the draft can be saved.
  var issues: [Field: Issue] {
    var issues: [Field: Issue] = [:]
    issues[.spendable] = issue(in: spendableText, required: true)
    issues[.income] = issue(in: incomeText, required: false)
    issues[.savings] = issue(in: savingsText, required: false)
    for bill in bills {
      if bill.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        issues[.billName(bill.id)] = .required
      }
      issues[.billAmount(bill.id)] = issue(in: bill.amountText, required: true)
    }
    return issues
  }

  var canSave: Bool { issues.isEmpty }

  /// Spendable − bills − savings, or `nil` while spendable is missing or any amount is invalid.
  var availableCents: Int? {
    guard case .cents(let spendable) = parse(spendableText),
      let savings = centsOrZero(savingsText)
    else { return nil }
    var billsCents = 0
    for bill in bills {
      guard let amount = centsOrZero(bill.amountText) else { return nil }
      billsCents += amount
    }
    return spendable - billsCents - savings
  }

  /// Bills and savings use up all of spendable. Saving is still allowed.
  var showsLowAvailableWarning: Bool {
    guard let availableCents else { return false }
    return availableCents <= 0
  }

  /// The entered income, if it's a valid amount.
  var incomeCents: Int? {
    guard case .cents(let cents) = parse(incomeText) else { return nil }
    return cents
  }

  /// Whether "Use income" would change spendable.
  var canUseIncome: Bool {
    guard let incomeCents, incomeCents > 0 else { return false }
    return parse(spendableText) != .cents(incomeCents)
  }

  // MARK: - Editing

  /// Copies the entered income into spendable.
  mutating func useIncomeForSpendable() {
    guard let incomeCents else { return }
    spendableText = Self.text(fromCents: incomeCents)
  }

  mutating func addBill() {
    bills.append(Bill())
  }

  // MARK: - Saving

  /// Inserts a new budget built from the draft, or returns `nil` if the draft has issues.
  ///
  /// Carryover is set directly rather than through `Budget.setCarryover`: a new budget has no
  /// past period for a recorded change to wait out.
  func insertBudget(into context: ModelContext, calendar: Calendar) -> Budget? {
    guard let values else { return nil }
    let budget = Budget(
      periodLength: periodLength,
      periodStart: calendar.startOfDay(for: periodStart),
      spendablePerPeriodCents: values.spendableCents,
      incomeCents: values.incomeCents,
      savingsCents: values.savingsCents,
      carryoverEnabled: carryoverEnabled,
      timeZoneIdentifier: calendar.timeZone.identifier
    )
    context.insert(budget)
    apply(values.bills, to: budget, currentPeriod: nil, now: nil)
    return budget
  }

  /// Writes the draft to an existing budget. Returns `false` and changes nothing if the draft has
  /// issues.
  ///
  /// Mid-period edits never rewrite the past: period changes go through `Budget.updatePeriod`
  /// (ending the current period today), carryover through `Budget.setCarryover` (from the next
  /// period), and a changed available amount is recorded with `Budget.recordAmountChange` so it
  /// applies from today.
  @discardableResult
  func apply(to budget: Budget, now: Date, calendar: Calendar) -> Bool {
    guard let values else { return false }
    let previousAvailableCents = budget.availablePerPeriodCents
    budget.updatePeriod(
      periodLength,
      start: calendar.startOfDay(for: periodStart),
      now: now,
      calendar: calendar
    )
    budget.spendablePerPeriodCents = values.spendableCents
    budget.incomeCents = values.incomeCents
    budget.savingsCents = values.savingsCents
    budget.setCarryover(carryoverEnabled, now: now, calendar: calendar)
    let engine = AllowanceEngine(calendar: calendar)
    let current = engine.period(containing: now, of: BudgetSnapshot(budget))
    apply(values.bills, to: budget, currentPeriod: current, now: now)
    budget.recordAmountChange(from: previousAvailableCents, now: now, calendar: calendar)
    return true
  }

  // MARK: - Mid-period changes

  /// Whether saving would change the available amount. The new amount applies from today.
  func changesAvailable(of budget: Budget) -> Bool {
    guard let availableCents else { return false }
    return availableCents != budget.availablePerPeriodCents
  }

  /// Whether saving would change the period length or payday.
  func changesSchedule(of budget: Budget, calendar: Calendar) -> Bool {
    let start = calendar.startOfDay(for: periodStart)
    return periodLength != budget.periodLength || start != budget.periodStart
  }

  /// What saving the draft's period length and payday would do today, for the confirm dialog.
  /// `nil` if the schedule is unchanged or no period has started yet, so nothing ends.
  func schedulePreview(
    for budget: Budget,
    expenses: [ExpenseSnapshot],
    now: Date,
    calendar: Calendar
  ) -> ScheduleChangePreview? {
    guard changesSchedule(of: budget, calendar: calendar) else { return nil }
    return AllowanceEngine(calendar: calendar).scheduleChangePreview(
      budget: BudgetSnapshot(budget),
      expenses: expenses,
      length: periodLength,
      start: periodStart,
      now: now
    )
  }

  /// When the draft's carryover setting would start to apply: the next period boundary after
  /// `now` under the draft's schedule. `nil` when it matches the setting in effect this period.
  func carryoverChangeDate(for budget: Budget, now: Date, calendar: Calendar) -> Date? {
    let engine = AllowanceEngine(calendar: calendar)
    let snapshot = BudgetSnapshot(budget).changingSchedule(
      to: periodLength,
      start: periodStart,
      now: now,
      calendar: calendar
    )
    let current = engine.period(containing: now, of: snapshot)
    let inEffect = engine.isCarryoverEnabled(atBoundary: current.start, budget: snapshot)
    return carryoverEnabled == inEffect ? nil : current.end
  }

  private struct Values {
    var spendableCents: Int
    var incomeCents: Int?
    var savingsCents: Int
    var bills: [ParsedBill]
  }

  private struct ParsedBill {
    var bill: Bill
    var amountCents: Int
  }

  private var values: Values? {
    guard issues.isEmpty,
      case .cents(let spendable) = parse(spendableText),
      let savings = centsOrZero(savingsText)
    else { return nil }
    var parsedBills: [ParsedBill] = []
    for bill in bills {
      guard case .cents(let amount) = parse(bill.amountText) else { return nil }
      parsedBills.append(ParsedBill(bill: bill, amountCents: amount))
    }
    return Values(
      spendableCents: spendable,
      incomeCents: incomeCents,
      savingsCents: savings,
      bills: parsedBills
    )
  }

  /// Updates bills edited in the draft, inserts new ones, and deletes ones removed from it. Bills
  /// marked paid or skipped in `currentPeriod` keep the period's total right when their amount
  /// changes (see `Budget.rebaseMark`).
  private func apply(
    _ parsedBills: [ParsedBill],
    to budget: Budget,
    currentPeriod: BudgetPeriod?,
    now: Date?
  ) {
    let keptIDs = Set(parsedBills.compactMap { $0.bill.modelID })
    for bill in budget.fixedBills where !keptIDs.contains(bill.persistentModelID) {
      if let currentPeriod, let now {
        budget.rebaseMark(
          of: bill, releasedCents: bill.amountCents, in: currentPeriod, now: now
        )
      }
      budget.fixedBills.removeAll { $0 === bill }
      budget.modelContext?.delete(bill)
    }
    for parsed in parsedBills {
      let name = parsed.bill.name.trimmingCharacters(in: .whitespacesAndNewlines)
      if let modelID = parsed.bill.modelID,
        let existing = budget.fixedBills.first(where: { $0.persistentModelID == modelID })
      {
        if let currentPeriod, let now {
          let releasedCents = existing.amountCents - parsed.amountCents
          budget.rebaseMark(
            of: existing, releasedCents: releasedCents, in: currentPeriod, now: now
          )
        }
        existing.name = name
        existing.amountCents = parsed.amountCents
        existing.dueDay = parsed.bill.dueDay
      } else {
        let bill = FixedBill(
          name: name,
          amountCents: parsed.amountCents,
          dueDay: parsed.bill.dueDay
        )
        budget.modelContext?.insert(bill)
        budget.fixedBills.append(bill)
      }
    }
  }

  // MARK: - Parsing and formatting

  /// Parses typed dollars into cents, e.g. `"$1,234.5"` → `123_450` in `en_US`.
  static func parseAmount(_ text: String, locale: Locale = .autoupdatingCurrent) -> ParsedAmount {
    var normalized: String
    if text.contains("$") {
      guard let dollars = normalizedDollarText(text) else { return .failure(.invalid) }
      normalized = dollars
    } else {
      let decimalSeparator = locale.decimalSeparator ?? "."
      let groupingSeparator = locale.groupingSeparator ?? ","
      normalized = text.filter { !$0.isWhitespace }
      if !groupingSeparator.isEmpty && groupingSeparator != decimalSeparator {
        normalized = normalized.replacingOccurrences(of: groupingSeparator, with: "")
      }
      normalized = normalized.replacingOccurrences(of: decimalSeparator, with: ".")
    }
    guard !normalized.isEmpty else { return .empty }

    let isNegative = normalized.hasPrefix("-")
    if isNegative {
      normalized.removeFirst()
    }
    let digits: ClosedRange<Character> = "0"..."9"
    let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count <= 2 else { return .failure(.invalid) }
    let whole = parts[0]
    let fraction = parts.count == 2 ? parts[1] : ""
    guard !(whole.isEmpty && fraction.isEmpty),
      whole.allSatisfy({ digits.contains($0) }),
      fraction.allSatisfy({ digits.contains($0) }),
      fraction.count <= 2
    else { return .failure(.invalid) }
    // Bail out before `Decimal` sees an absurdly long number.
    guard whole.drop(while: { $0 == "0" }).count <= 8 else { return .failure(.tooLarge) }

    let posix = Locale(identifier: "en_US_POSIX")
    let wholeText = whole.isEmpty ? "0" : String(whole)
    let fractionText = fraction.isEmpty ? "0" : String(fraction)
    guard let dollars = Decimal(string: "\(wholeText).\(fractionText)", locale: posix) else {
      return .failure(.invalid)
    }
    let cents = Money.cents(fromDollars: dollars)
    if isNegative && cents != 0 {
      return .failure(.negative)
    }
    guard cents <= maximumCents else { return .failure(.tooLarge) }
    return .cents(cents)
  }

  /// Dollar-prefixed input accepts either decimal separator and validates grouping first.
  private static func normalizedDollarText(_ text: String) -> String? {
    guard text.filter({ $0 == "$" }).count == 1 else { return nil }
    var amount = text.filter { !$0.isWhitespace && $0 != "$" }
    let isNegative = amount.hasPrefix("-")
    if isNegative {
      amount.removeFirst()
    }
    let digits: ClosedRange<Character> = "0"..."9"
    var whole = amount[...]
    var fraction = ""
    if let separator = amount.lastIndex(where: { $0 == "," || $0 == "." }) {
      let suffix = amount[amount.index(after: separator)...]
      if (1...2).contains(suffix.count) && suffix.allSatisfy({ digits.contains($0) }) {
        whole = amount[..<separator]
        fraction = String(suffix)
      }
    }
    let groups = whole.split(omittingEmptySubsequences: false) { $0 == "," || $0 == "." }
    guard let first = groups.first,
      !first.isEmpty,
      first.allSatisfy({ digits.contains($0) }),
      groups.count == 1 || first.count <= 3,
      groups.dropFirst().allSatisfy({ group in
        group.count == 3 && group.allSatisfy({ digits.contains($0) })
      })
    else { return nil }
    let sign = isNegative ? "-" : ""
    let integer = groups.joined()
    if fraction.isEmpty {
      return sign + integer
    }
    return sign + integer + "." + fraction
  }

  /// Formats editable USD with grouping and cents only when nonzero.
  /// Uses Latin digits and US separators with an explicit dollar sign for round trips.
  static func text(fromCents cents: Int) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = true
    formatter.minimumFractionDigits = cents % 100 == 0 ? 0 : 2
    formatter.maximumFractionDigits = 2
    let dollars = NSDecimalNumber(decimal: Money.dollars(fromCents: cents))
    let number = formatter.string(from: dollars) ?? dollars.stringValue
    return "$\(number)"
  }

  /// Reformats valid input as editable USD. Empty or invalid text is returned unchanged.
  static func displayText(for text: String, locale: Locale = .autoupdatingCurrent) -> String {
    guard case .cents(let cents) = parseAmount(text, locale: locale) else { return text }
    return Self.text(fromCents: cents)
  }

  private func parse(_ text: String) -> ParsedAmount {
    Self.parseAmount(text, locale: locale)
  }

  /// Cents for an optional amount: empty is zero, invalid is `nil`.
  private func centsOrZero(_ text: String) -> Int? {
    switch parse(text) {
    case .empty: 0
    case .cents(let cents): cents
    case .failure: nil
    }
  }

  private func issue(in text: String, required: Bool) -> Issue? {
    switch parse(text) {
    case .empty: required ? .required : nil
    case .cents: nil
    case .failure(let issue): issue
    }
  }
}
