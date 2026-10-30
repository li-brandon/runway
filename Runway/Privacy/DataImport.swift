import Foundation
import SwiftData

enum DataImportError: LocalizedError, Equatable {
  case malformed
  case unsupportedVersion(Int)
  case missingField(String)
  case invalidField(String)
  case negativeAmount(String)
  case amountTooLarge(String)
  case dateOutOfRange(String)
  case duplicateID(String)
  case danglingReference(String)
  case unsavedChanges

  var errorDescription: String? {
    switch self {
    case .malformed:
      "This file isn't a Runway backup, or it's damaged."
    case .unsupportedVersion(let version):
      "This backup uses format version \(version), which this version of Runway can't read."
    case .missingField(let field):
      "This backup is missing a required field: \(field)."
    case .invalidField(let field):
      "This backup has an invalid value for \(field)."
    case .negativeAmount(let field):
      "This backup has a negative amount for \(field)."
    case .amountTooLarge(let field):
      "This backup has an amount too large for \(field)."
    case .dateOutOfRange(let field):
      "This backup has an impossible date for \(field)."
    case .duplicateID(let section):
      "This backup lists the same ID twice in \(section)."
    case .danglingReference(let field):
      "This backup has a \(field) that points to a record that doesn't exist."
    case .unsavedChanges:
      "Runway is still saving your latest changes. Try importing again in a moment."
    }
  }
}

/// A backup that passed every check. Only `DataImport.validate` can make one, so `apply` can't
/// run on unchecked data.
struct ValidatedImport: Equatable, Sendable {
  let snapshot: RunwaySnapshot

  fileprivate init(snapshot: RunwaySnapshot) {
    self.snapshot = snapshot
  }
}

/// The checked backup waiting on the import alert. Any dismissal drops it, so it's only applied
/// if the alert's confirm button applies it.
struct ImportConfirmation: Equatable, Sendable {
  var pending: ValidatedImport?

  var isPresented: Bool {
    get { pending != nil }
    set { if !newValue { pending = nil } }
  }
}

/// Reads a JSON backup in two steps: `validate` touches no data, and `apply` replaces the store.
enum DataImport {
  /// Far above any real amount, and low enough that summing a whole store can't overflow `Int`,
  /// which would trap in the allowance engine. Looser than `BudgetDraft.maximumCents` because
  /// derived amounts, like available money after many bills, can legitimately exceed that.
  static let maximumMagnitudeCents = 10_000_000_000_000

  /// About a century either side of 2001. Far-off dates would make the engine walk huge numbers
  /// of periods.
  private static let maximumDateOffset: TimeInterval = 3_155_760_000

  private struct Header: Decodable {
    var formatVersion: Int
  }

  static func validate(_ data: Data) throws -> ValidatedImport {
    // The version comes first, so a newer format reports its version rather than a bad shape.
    let header = try decode(Header.self, from: data)
    try checkVersion(header.formatVersion)
    return try validate(decode(RunwaySnapshot.self, from: data))
  }

  static func validate(_ snapshot: RunwaySnapshot) throws -> ValidatedImport {
    try checkVersion(snapshot.formatVersion)

    let categoryIDs = try uniqueIDs(snapshot.categories.map(\.id), in: "categories")
    let budgetIDs = try uniqueIDs(snapshot.budgets.map(\.id), in: "budgets")
    let billIDs = try uniqueIDs(snapshot.fixedBills.map(\.id), in: "bills")
    _ = try uniqueIDs(snapshot.expenses.map(\.id), in: "expenses")
    _ = try uniqueIDs(snapshot.carryoverChanges.map(\.id), in: "carryover changes")
    _ = try uniqueIDs(snapshot.amountChanges.map(\.id), in: "amount changes")
    _ = try uniqueIDs(snapshot.scheduleChanges.map(\.id), in: "schedule changes")
    _ = try uniqueIDs(snapshot.extraMoney.map(\.id), in: "extra money")
    _ = try uniqueIDs(snapshot.billPayments.map(\.id), in: "bill payments")

    for category in snapshot.categories {
      try checkNotBlank(category.name, field: "category name")
    }
    // Other is the seed marker and where uncategorized expenses go.
    guard snapshot.categories.filter(\.isSystem).count == 1 else {
      throw DataImportError.invalidField("the system category")
    }

    for budget in snapshot.budgets {
      try checkDate(budget.periodStart, field: "budget start")
      try checkAmount(budget.spendablePerPeriodCents, field: "budget spendable")
      try checkAmount(budget.savingsCents, field: "budget savings")
      if let income = budget.incomeCents {
        try checkAmount(income, field: "budget income")
      }
    }

    for bill in snapshot.fixedBills {
      try checkReference(bill.budgetID, in: budgetIDs, field: "bill budget")
      try checkNotBlank(bill.name, field: "bill name")
      try checkAmount(bill.amountCents, field: "bill amount")
      if let dueDay = bill.dueDay, !(1...31).contains(dueDay) {
        throw DataImportError.invalidField("bill due day")
      }
    }

    for expense in snapshot.expenses {
      try checkReference(expense.categoryID, in: categoryIDs, field: "expense category")
      // Refunds are negative expenses, so only the size is limited.
      try checkSignedAmount(expense.amountCents, field: "expense amount")
      try checkDate(expense.date, field: "expense date")
      try checkDate(expense.createdAt, field: "expense creation date")
    }

    for change in snapshot.carryoverChanges {
      try checkReference(change.budgetID, in: budgetIDs, field: "carryover change budget")
      try checkDate(change.effectiveAt, field: "carryover change date")
    }

    for change in snapshot.amountChanges {
      try checkReference(change.budgetID, in: budgetIDs, field: "amount change budget")
      // Available money is negative when bills and savings exceed spendable.
      try checkSignedAmount(change.previousAvailableCents, field: "previous available amount")
      try checkDate(change.effectiveAt, field: "amount change date")
    }

    for change in snapshot.scheduleChanges {
      try checkReference(change.budgetID, in: budgetIDs, field: "schedule change budget")
      try checkDate(change.previousPeriodStart, field: "previous period start")
      try checkDate(change.effectiveAt, field: "schedule change date")
    }

    for extra in snapshot.extraMoney {
      try checkReference(extra.budgetID, in: budgetIDs, field: "extra money budget")
      try checkAmount(extra.amountCents, field: "extra money amount")
      try checkDate(extra.date, field: "extra money date")
    }

    for payment in snapshot.billPayments {
      try checkReference(payment.budgetID, in: budgetIDs, field: "bill payment budget")
      try checkReference(payment.billID, in: billIDs, field: "bill payment bill")
      try checkAmount(payment.paidCents, field: "bill payment amount")
      // Rebasing a mark and undoing a credit can both take these below zero.
      try checkSignedAmount(payment.plannedCents, field: "bill payment planned amount")
      try checkSignedAmount(payment.adjustmentCents, field: "bill payment adjustment")
      try checkDate(payment.date, field: "bill payment date")
    }

    return ValidatedImport(snapshot: snapshot)
  }

  /// Replaces everything in `context`'s store in a single save. The work is staged in a separate
  /// scratch context on the same container, so a failure just discards that context and neither
  /// the store nor `context` changes. Rolling back staged deletes and inserts in place traps in
  /// SwiftData, so there is deliberately no rollback here. Unsaved changes in `context` throw
  /// before anything is staged. `save` replaces the scratch context's save so tests can fail it.
  static func apply(
    _ validated: ValidatedImport,
    to context: ModelContext,
    save: ((ModelContext) throws -> Void)? = nil
  ) throws {
    guard !context.hasChanges else { throw DataImportError.unsavedChanges }
    let scratch = ModelContext(context.container)
    scratch.autosaveEnabled = false
    try DataReset.deleteAll(in: scratch)
    try insert(validated.snapshot, into: scratch)
    if let save {
      try save(scratch)
    } else {
      try scratch.save()
    }
  }

  private static func insert(_ snapshot: RunwaySnapshot, into context: ModelContext) throws {
    var categories: [Int: Category] = [:]
    var other: Category?
    for record in snapshot.categories {
      let category = Category(
        name: record.name,
        symbol: record.symbol,
        colorHex: record.colorHex,
        sortOrder: record.sortOrder,
        isSystem: record.isSystem
      )
      context.insert(category)
      categories[record.id] = category
      if record.isSystem { other = category }
    }

    var budgets: [Int: Budget] = [:]
    for record in snapshot.budgets {
      let budget = Budget(
        periodLength: record.periodLength,
        periodStart: record.periodStart,
        spendablePerPeriodCents: record.spendablePerPeriodCents,
        incomeCents: record.incomeCents,
        savingsCents: record.savingsCents,
        carryoverEnabled: record.carryoverEnabled,
        timeZoneIdentifier: record.timeZoneIdentifier
      )
      context.insert(budget)
      budgets[record.id] = budget
    }
    func budget(_ id: Int?) -> Budget? {
      id.flatMap { budgets[$0] }
    }

    var bills: [Int: FixedBill] = [:]
    for record in snapshot.fixedBills {
      let bill = FixedBill(
        name: record.name,
        amountCents: record.amountCents,
        dueDay: record.dueDay
      )
      context.insert(bill)
      bill.budget = budget(record.budgetID)
      bills[record.id] = bill
    }

    // Passing a category always, so the service never fetches while deletes are pending. An
    // expense with no category gets Other, the same repair `CategoryService.seed` makes at launch.
    let service = CategoryService(context: context)
    for record in snapshot.expenses {
      try service.createExpense(
        amountCents: record.amountCents,
        note: record.note,
        date: record.date,
        category: record.categoryID.flatMap { categories[$0] } ?? other,
        now: record.createdAt
      )
    }

    for record in snapshot.carryoverChanges {
      let change = CarryoverChange(
        enabled: record.enabled,
        previousEnabled: record.previousEnabled,
        effectiveAt: record.effectiveAt
      )
      context.insert(change)
      change.budget = budget(record.budgetID)
    }

    for record in snapshot.amountChanges {
      let change = AmountChange(
        previousAvailableCents: record.previousAvailableCents,
        effectiveAt: record.effectiveAt
      )
      context.insert(change)
      change.budget = budget(record.budgetID)
    }

    for record in snapshot.scheduleChanges {
      let change = ScheduleChange(
        previousPeriodLength: record.previousPeriodLength,
        previousPeriodStart: record.previousPeriodStart,
        effectiveAt: record.effectiveAt
      )
      context.insert(change)
      change.budget = budget(record.budgetID)
    }

    for record in snapshot.extraMoney {
      let extra = ExtraMoney(amountCents: record.amountCents, note: record.note, date: record.date)
      context.insert(extra)
      extra.budget = budget(record.budgetID)
    }

    for record in snapshot.billPayments {
      let payment = BillPayment(
        isSkipped: record.isSkipped,
        isCleared: record.isCleared,
        plannedCents: record.plannedCents,
        paidCents: record.paidCents,
        adjustmentCents: record.adjustmentCents,
        sequence: record.sequence,
        date: record.date
      )
      context.insert(payment)
      payment.budget = budget(record.budgetID)
      payment.bill = record.billID.flatMap { bills[$0] }
    }
  }

  // MARK: - Checks

  private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .deferredToDate
    do {
      return try decoder.decode(type, from: data)
    } catch DecodingError.keyNotFound(let key, _) {
      throw DataImportError.missingField(key.stringValue)
    } catch DecodingError.valueNotFound(_, let context) {
      throw DataImportError.missingField(context.codingPath.last?.stringValue ?? "a value")
    } catch {
      throw DataImportError.malformed
    }
  }

  private static func checkVersion(_ version: Int) throws {
    guard version == RunwaySnapshot.currentFormatVersion else {
      throw DataImportError.unsupportedVersion(version)
    }
  }

  private static func uniqueIDs(_ ids: [Int], in section: String) throws -> Set<Int> {
    let unique = Set(ids)
    guard unique.count == ids.count else { throw DataImportError.duplicateID(section) }
    return unique
  }

  private static func checkReference(_ id: Int?, in ids: Set<Int>, field: String) throws {
    guard let id, !ids.contains(id) else { return }
    throw DataImportError.danglingReference(field)
  }

  private static func checkAmount(_ cents: Int, field: String) throws {
    guard cents >= 0 else { throw DataImportError.negativeAmount(field) }
    try checkSignedAmount(cents, field: field)
  }

  private static func checkSignedAmount(_ cents: Int, field: String) throws {
    guard cents.magnitude <= UInt(maximumMagnitudeCents) else {
      throw DataImportError.amountTooLarge(field)
    }
  }

  private static func checkDate(_ date: Date, field: String) throws {
    guard abs(date.timeIntervalSinceReferenceDate) <= maximumDateOffset else {
      throw DataImportError.dateOutOfRange(field)
    }
  }

  private static func checkNotBlank(_ text: String, field: String) throws {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw DataImportError.invalidField(field)
    }
  }
}
