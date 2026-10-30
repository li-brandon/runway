import CoreTransferable
import Foundation
import SwiftData
import UniformTypeIdentifiers

/// A full copy of the store: one flat list per SwiftData model. Relationships are `id`s that only
/// mean something inside one file. A list's `id`s are unique within that list.
///
/// Dates are seconds since 2001-01-01 UTC, the only JSON form that keeps a `Date` exact. Optional
/// references mirror the models: a bill's payments outlive the bill, for example.
struct RunwaySnapshot: Codable, Equatable, Sendable {
  static let currentFormatVersion = 1

  struct CategoryRecord: Codable, Equatable, Sendable {
    var id: Int
    var name: String
    var symbol: String
    var colorHex: String
    var sortOrder: Int
    var isSystem: Bool
  }

  struct BudgetRecord: Codable, Equatable, Sendable {
    var id: Int
    var periodLength: PeriodLength
    var periodStart: Date
    var spendablePerPeriodCents: Int
    var incomeCents: Int?
    var savingsCents: Int
    var carryoverEnabled: Bool
    var timeZoneIdentifier: String
  }

  struct FixedBillRecord: Codable, Equatable, Sendable {
    var id: Int
    var budgetID: Int?
    var name: String
    var amountCents: Int
    var dueDay: Int?
  }

  struct ExpenseRecord: Codable, Equatable, Sendable {
    var id: Int
    var categoryID: Int?
    var amountCents: Int
    var note: String
    var date: Date
    var createdAt: Date
  }

  struct CarryoverChangeRecord: Codable, Equatable, Sendable {
    var id: Int
    var budgetID: Int?
    var enabled: Bool
    var previousEnabled: Bool
    var effectiveAt: Date
  }

  struct AmountChangeRecord: Codable, Equatable, Sendable {
    var id: Int
    var budgetID: Int?
    var previousAvailableCents: Int
    var effectiveAt: Date
  }

  struct ScheduleChangeRecord: Codable, Equatable, Sendable {
    var id: Int
    var budgetID: Int?
    var previousPeriodLength: PeriodLength
    var previousPeriodStart: Date
    var effectiveAt: Date
  }

  struct ExtraMoneyRecord: Codable, Equatable, Sendable {
    var id: Int
    var budgetID: Int?
    var amountCents: Int
    var note: String
    var date: Date
  }

  struct BillPaymentRecord: Codable, Equatable, Sendable {
    var id: Int
    var budgetID: Int?
    var billID: Int?
    var isSkipped: Bool
    var isCleared: Bool
    var plannedCents: Int
    var paidCents: Int
    var adjustmentCents: Int
    var sequence: Int
    var date: Date
  }

  var formatVersion: Int
  var exportedAt: Date
  var categories: [CategoryRecord]
  var budgets: [BudgetRecord]
  var fixedBills: [FixedBillRecord]
  var expenses: [ExpenseRecord]
  var carryoverChanges: [CarryoverChangeRecord]
  var amountChanges: [AmountChangeRecord]
  var scheduleChanges: [ScheduleChangeRecord]
  var extraMoney: [ExtraMoneyRecord]
  var billPayments: [BillPaymentRecord]
}

/// Builds the JSON backup and the expenses spreadsheet. Neither changes the store.
enum DataExport {
  static func snapshot(of context: ModelContext, now: Date = .now) throws -> RunwaySnapshot {
    let categories = try context.fetch(FetchDescriptor<Category>())
      .sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
    let budgets = try context.fetch(FetchDescriptor<Budget>())
      .sorted { $0.periodStart < $1.periodStart }
    let bills = try context.fetch(FetchDescriptor<FixedBill>())
      .sorted { ($0.name, $0.amountCents) < ($1.name, $1.amountCents) }
    let expenses = try sortedExpenses(in: context)
    let carryover = try context.fetch(FetchDescriptor<CarryoverChange>())
      .sorted { $0.effectiveAt < $1.effectiveAt }
    let amounts = try context.fetch(FetchDescriptor<AmountChange>())
      .sorted { $0.effectiveAt < $1.effectiveAt }
    let schedules = try context.fetch(FetchDescriptor<ScheduleChange>())
      .sorted { $0.effectiveAt < $1.effectiveAt }
    let extras = try context.fetch(FetchDescriptor<ExtraMoney>())
      .sorted { ($0.date, $0.amountCents) < ($1.date, $1.amountCents) }
    let payments = try context.fetch(FetchDescriptor<BillPayment>())
      .sorted { ($0.date, $0.sequence) < ($1.date, $1.sequence) }

    let categoryIDs = identifiers(of: categories)
    let budgetIDs = identifiers(of: budgets)
    let billIDs = identifiers(of: bills)
    func budgetID(_ budget: Budget?) -> Int? {
      budget.flatMap { budgetIDs[$0.persistentModelID] }
    }

    return RunwaySnapshot(
      formatVersion: RunwaySnapshot.currentFormatVersion,
      exportedAt: now,
      categories: categories.enumerated().map { index, category in
        RunwaySnapshot.CategoryRecord(
          id: index + 1,
          name: category.name,
          symbol: category.symbol,
          colorHex: category.colorHex,
          sortOrder: category.sortOrder,
          isSystem: category.isSystem
        )
      },
      budgets: budgets.enumerated().map { index, budget in
        RunwaySnapshot.BudgetRecord(
          id: index + 1,
          periodLength: budget.periodLength,
          periodStart: budget.periodStart,
          spendablePerPeriodCents: budget.spendablePerPeriodCents,
          incomeCents: budget.incomeCents,
          savingsCents: budget.savingsCents,
          carryoverEnabled: budget.carryoverEnabled,
          timeZoneIdentifier: budget.timeZoneIdentifier
        )
      },
      fixedBills: bills.enumerated().map { index, bill in
        RunwaySnapshot.FixedBillRecord(
          id: index + 1,
          budgetID: budgetID(bill.budget),
          name: bill.name,
          amountCents: bill.amountCents,
          dueDay: bill.dueDay
        )
      },
      expenses: expenses.enumerated().map { index, expense in
        RunwaySnapshot.ExpenseRecord(
          id: index + 1,
          categoryID: expense.category.flatMap { categoryIDs[$0.persistentModelID] },
          amountCents: expense.amountCents,
          note: expense.note,
          date: expense.date,
          createdAt: expense.createdAt
        )
      },
      carryoverChanges: carryover.enumerated().map { index, change in
        RunwaySnapshot.CarryoverChangeRecord(
          id: index + 1,
          budgetID: budgetID(change.budget),
          enabled: change.enabled,
          previousEnabled: change.previousEnabled,
          effectiveAt: change.effectiveAt
        )
      },
      amountChanges: amounts.enumerated().map { index, change in
        RunwaySnapshot.AmountChangeRecord(
          id: index + 1,
          budgetID: budgetID(change.budget),
          previousAvailableCents: change.previousAvailableCents,
          effectiveAt: change.effectiveAt
        )
      },
      scheduleChanges: schedules.enumerated().map { index, change in
        RunwaySnapshot.ScheduleChangeRecord(
          id: index + 1,
          budgetID: budgetID(change.budget),
          previousPeriodLength: change.previousPeriodLength,
          previousPeriodStart: change.previousPeriodStart,
          effectiveAt: change.effectiveAt
        )
      },
      extraMoney: extras.enumerated().map { index, extra in
        RunwaySnapshot.ExtraMoneyRecord(
          id: index + 1,
          budgetID: budgetID(extra.budget),
          amountCents: extra.amountCents,
          note: extra.note,
          date: extra.date
        )
      },
      billPayments: payments.enumerated().map { index, payment in
        RunwaySnapshot.BillPaymentRecord(
          id: index + 1,
          budgetID: budgetID(payment.budget),
          billID: payment.bill.flatMap { billIDs[$0.persistentModelID] },
          isSkipped: payment.isSkipped,
          isCleared: payment.isCleared,
          plannedCents: payment.plannedCents,
          paidCents: payment.paidCents,
          adjustmentCents: payment.adjustmentCents,
          sequence: payment.sequence,
          date: payment.date
        )
      }
    )
  }

  static func jsonData(from snapshot: RunwaySnapshot) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .deferredToDate
    return try encoder.encode(snapshot)
  }

  // MARK: - CSV

  static let csvHeader = "date,amount,category,note,created_at"

  /// One row per expense, oldest first, with RFC 4180 CRLF line endings. Dates are ISO 8601 in
  /// `timeZone`. Amounts are plain dollars, like `12.50`, and refunds are negative.
  static func expensesCSV(
    in context: ModelContext,
    timeZone: TimeZone = .current
  ) throws -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = timeZone
    let rows = try sortedExpenses(in: context).map { expense in
      [
        formatter.string(from: expense.date),
        csvAmount(cents: expense.amountCents),
        expense.category?.name ?? "",
        expense.note,
        formatter.string(from: expense.createdAt),
      ]
      .map(csvField)
      .joined(separator: ",")
    }
    return ([csvHeader] + rows).map { $0 + "\r\n" }.joined()
  }

  /// Quotes a field holding a quote, comma, or line break, and doubles its quotes. Checks scalars
  /// because Swift treats `\r\n` as one `Character`, so `contains("\n")` would miss it.
  static func csvField(_ field: String) -> String {
    let needsQuotes = field.unicodeScalars.contains { "\",\r\n".unicodeScalars.contains($0) }
    guard needsQuotes else { return field }
    return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }

  /// Formats with integer arithmetic so money never goes through `Double` or a locale.
  static func csvAmount(cents: Int) -> String {
    let fraction = cents.magnitude % 100
    let padding = fraction < 10 ? "0" : ""
    return "\(cents < 0 ? "-" : "")\(cents.magnitude / 100).\(padding)\(fraction)"
  }

  private static func sortedExpenses(in context: ModelContext) throws -> [Expense] {
    try context.fetch(FetchDescriptor<Expense>()).sorted {
      ($0.date, $0.createdAt, $0.amountCents, $0.note)
        < ($1.date, $1.createdAt, $1.amountCents, $1.note)
    }
  }

  /// One-based position of each model, used as its `id` in the file.
  private static func identifiers(
    of models: [some PersistentModel]
  ) -> [PersistentIdentifier: Int] {
    var result: [PersistentIdentifier: Int] = [:]
    for (index, model) in models.enumerated() {
      result[model.persistentModelID] = index + 1
    }
    return result
  }
}

/// The JSON backup as a named file for `ShareLink`. Sharing from memory leaves no copy of the
/// user's data in a temporary directory.
struct JSONExportFile: Transferable, Sendable {
  let data: Data
  let fileName: String

  init(data: Data, date: Date) {
    self.data = data
    fileName = "runway-backup-\(date.formatted(.iso8601.year().month().day())).json"
  }

  static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(exportedContentType: .json) { $0.data }
      .suggestedFileName { $0.fileName }
  }
}

/// The expenses spreadsheet as a named file for `ShareLink`.
struct CSVExportFile: Transferable, Sendable {
  let data: Data
  let fileName: String

  init(text: String, date: Date) {
    data = Data(text.utf8)
    fileName = "runway-expenses-\(date.formatted(.iso8601.year().month().day())).csv"
  }

  static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(exportedContentType: .commaSeparatedText) { $0.data }
      .suggestedFileName { $0.fileName }
  }
}
