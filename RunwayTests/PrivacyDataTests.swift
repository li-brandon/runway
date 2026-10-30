import Foundation
import SwiftData
import Testing

@testable import Runway

/// JSON and CSV export, import validation and replacement, and reset.
struct PrivacyDataTests {
  let calendar = Calendar.gregorian("America/Chicago")

  private func makeContext() throws -> ModelContext {
    ModelContext(try RunwayModelContainer.make(inMemory: true))
  }

  /// A store with at least one of every model, non-default values, and sub-second dates.
  private func seedEverything(into context: ModelContext) throws {
    let service = CategoryService(context: context)
    try service.seed()
    let food = try #require(try service.categories().first { $0.name == "Food" })
    food.colorHex = "#34C759"

    let budget = Budget(
      periodLength: .monthly,
      periodStart: calendar.date(2026, 6, 1),
      spendablePerPeriodCents: 240_000,
      incomeCents: 285_000,
      savingsCents: 20_000,
      carryoverEnabled: false,
      timeZoneIdentifier: "America/Chicago"
    )
    context.insert(budget)
    let rent = FixedBill(name: "Rent", amountCents: 110_000, dueDay: 1)
    context.insert(rent)
    rent.budget = budget
    let phone = FixedBill(name: "Phone", amountCents: 4_500)
    context.insert(phone)
    phone.budget = budget

    try service.createExpense(
      amountCents: 1_250,
      note: "Lunch, \"with\" Sam\nand Alex",
      date: calendar.date(2026, 6, 2, 12).addingTimeInterval(0.123_456),
      category: food,
      now: calendar.date(2026, 6, 2, 13).addingTimeInterval(0.654_321)
    )
    try service.createExpense(
      amountCents: -500,
      note: "Returned item",
      date: calendar.date(2026, 6, 3, 9),
      now: calendar.date(2026, 6, 3, 9)
    )

    let carryover = CarryoverChange(
      enabled: false,
      previousEnabled: true,
      effectiveAt: calendar.date(2026, 7, 1)
    )
    context.insert(carryover)
    carryover.budget = budget
    let amount = AmountChange(
      previousAvailableCents: -2_500,
      effectiveAt: calendar.date(2026, 6, 4)
    )
    context.insert(amount)
    amount.budget = budget
    let schedule = ScheduleChange(
      previousPeriodLength: .weekly,
      previousPeriodStart: calendar.date(2026, 5, 1),
      effectiveAt: calendar.date(2026, 6, 1)
    )
    context.insert(schedule)
    schedule.budget = budget
    let extra = ExtraMoney(amountCents: 15_000, note: "Gift", date: calendar.date(2026, 6, 5))
    context.insert(extra)
    extra.budget = budget

    let paid = BillPayment(
      isSkipped: false,
      plannedCents: 110_000,
      paidCents: 100_000,
      adjustmentCents: 10_000,
      sequence: 1,
      date: calendar.date(2026, 6, 6)
    )
    context.insert(paid)
    paid.budget = budget
    paid.bill = rent
    // A mark that outlived its deleted bill, with a credit being taken back.
    let orphaned = BillPayment(
      isSkipped: true,
      isCleared: true,
      plannedCents: -300,
      paidCents: 0,
      adjustmentCents: -4_500,
      sequence: 2,
      date: calendar.date(2026, 6, 7)
    )
    context.insert(orphaned)
    orphaned.budget = budget
    try context.save()
  }

  private func validSnapshot() throws -> RunwaySnapshot {
    let context = try makeContext()
    try seedEverything(into: context)
    return try DataExport.snapshot(of: context, now: calendar.date(2026, 6, 10))
  }

  /// Every model's row count, so tests can see a store is untouched.
  private func counts(in context: ModelContext) throws -> [Int] {
    [
      try context.fetchCount(FetchDescriptor<Budget>()),
      try context.fetchCount(FetchDescriptor<FixedBill>()),
      try context.fetchCount(FetchDescriptor<Expense>()),
      try context.fetchCount(FetchDescriptor<Runway.Category>()),
      try context.fetchCount(FetchDescriptor<CarryoverChange>()),
      try context.fetchCount(FetchDescriptor<AmountChange>()),
      try context.fetchCount(FetchDescriptor<ScheduleChange>()),
      try context.fetchCount(FetchDescriptor<ExtraMoney>()),
      try context.fetchCount(FetchDescriptor<BillPayment>()),
    ]
  }

  // MARK: - Round trip

  @Test("Tests and snapshots cover every model in the schema")
  func coversSchema() throws {
    // A new model must be added to `RunwaySnapshot`, `counts(in:)`, and this number.
    #expect(RunwaySchemaV1.models.count == 9)
    let context = try makeContext()
    try seedEverything(into: context)
    #expect(try counts(in: context).allSatisfy { $0 > 0 })
  }

  @Test("A JSON export imported into another store preserves everything")
  func roundTrip() throws {
    let source = try makeContext()
    try seedEverything(into: source)
    let now = calendar.date(2026, 6, 10)
    let exported = try DataExport.snapshot(of: source, now: now)
    let data = try DataExport.jsonData(from: exported)

    let destination = try makeContext()
    try DataImport.apply(try DataImport.validate(data), to: destination)

    let loaded = ModelContext(destination.container)
    #expect(try DataExport.snapshot(of: loaded, now: now) == exported)
    #expect(try counts(in: loaded) == counts(in: source))

    // Spot-check real relationships and values rather than relying on IDs alone.
    let budget = try #require(try loaded.fetch(FetchDescriptor<Budget>()).first)
    #expect(budget.fixedBills.map(\.name).sorted() == ["Phone", "Rent"])
    #expect(budget.billPayments.count == 2)
    #expect(budget.billPayments.first { $0.sequence == 1 }?.bill?.name == "Rent")
    #expect(budget.billPayments.first { $0.sequence == 2 }?.bill == nil)
    let expenses = try loaded.fetch(FetchDescriptor<Expense>(sortBy: [SortDescriptor(\.date)]))
    #expect(expenses[0].category?.name == "Food")
    #expect(expenses[0].date == calendar.date(2026, 6, 2, 12).addingTimeInterval(0.123_456))
    #expect(expenses[1].amountCents == -500)
    #expect(expenses[1].category?.isSystem == true)
  }

  @Test("Import replaces all existing data")
  func importReplaces() throws {
    let context = try makeContext()
    let service = CategoryService(context: context)
    try service.seed()
    try service.add(name: "Old category", symbol: "tag", colorHex: "#8E8E93")
    try service.createExpense(amountCents: 999, note: "Old")
    context.insert(Budget(periodStart: .now, spendablePerPeriodCents: 1))
    try context.save()

    let snapshot = try validSnapshot()
    try DataImport.apply(try DataImport.validate(snapshot), to: context)

    let loaded = ModelContext(context.container)
    #expect(try DataExport.snapshot(of: loaded, now: snapshot.exportedAt) == snapshot)
    let names = try loaded.fetch(FetchDescriptor<Runway.Category>()).map(\.name)
    #expect(!names.contains("Old category"))
  }

  @Test("Validating never changes the store; only apply does")
  func validateDoesNotApply() throws {
    let context = try makeContext()
    try CategoryService(context: context).seed()
    try context.save()
    let before = try counts(in: context)

    let validated = try DataImport.validate(try validSnapshot())
    #expect(try counts(in: context) == before)
    #expect(!context.hasChanges)

    try DataImport.apply(validated, to: context)
    #expect(try counts(in: context) != before)
  }

  @Test("A failed import save rolls back and leaves existing data unchanged")
  func failedSaveRollsBack() throws {
    struct SaveFailure: Error {}

    let context = try makeContext()
    try seedEverything(into: context)
    let now = calendar.date(2026, 6, 10)
    let before = try DataExport.snapshot(of: context, now: now)
    let countsBefore = try counts(in: context)

    // Differs from the store, so a rollback that kept the import would show up below.
    let empty = try makeContext()
    try CategoryService(context: empty).seed()
    try empty.save()
    let validated = try DataImport.validate(try DataExport.snapshot(of: empty))

    var saveAttempts = 0
    #expect(throws: SaveFailure.self) {
      try DataImport.apply(validated, to: context) {
        saveAttempts += 1
        // Proves the failure comes after the replacement was staged, with something to undo.
        #expect(context.hasChanges)
        throw SaveFailure()
      }
    }
    #expect(saveAttempts == 1)
    #expect(!context.hasChanges)

    // Both the failed context and a fresh read of the store see the original data.
    for loaded in [context, ModelContext(context.container)] {
      #expect(try counts(in: loaded) == countsBefore)
      #expect(try DataExport.snapshot(of: loaded, now: now) == before)

      let budget = try #require(try loaded.fetch(FetchDescriptor<Budget>()).first)
      #expect(budget.spendablePerPeriodCents == 240_000)
      #expect(budget.fixedBills.map(\.name).sorted() == ["Phone", "Rent"])
      let expenses = try loaded.fetch(FetchDescriptor<Expense>(sortBy: [SortDescriptor(\.date)]))
      #expect(expenses.map(\.amountCents) == [1_250, -500])
      #expect(expenses[0].category?.name == "Food")
    }
  }

  @Test("Cancelling the import confirmation drops the backup without applying it")
  func cancelImportConfirmation() throws {
    let context = try makeContext()
    try seedEverything(into: context)
    let now = calendar.date(2026, 6, 10)
    let before = try DataExport.snapshot(of: context, now: now)

    var confirmation = ImportConfirmation()
    #expect(!confirmation.isPresented)
    confirmation.pending = try DataImport.validate(try validSnapshot())
    #expect(confirmation.isPresented)

    // What the alert does through its binding when Cancel is tapped.
    confirmation.isPresented = false

    #expect(confirmation.pending == nil)
    #expect(!context.hasChanges)
    #expect(try DataExport.snapshot(of: context, now: now) == before)
  }

  @MainActor
  @Test("The data replace action compares by id and still runs its closure")
  func dataReplaceAction() {
    var calls = 0
    let id = UUID()
    let action = DataReplaceAction(id: id) { calls += 1 }

    #expect(action == DataReplaceAction(id: id) {})
    #expect(action != DataReplaceAction(id: UUID()) {})
    #expect(DataReplaceAction.doNothing == .doNothing)

    action()
    #expect(calls == 1)
  }

  @Test("A backup of an empty store with only categories imports and clears the budget")
  func importEmptyBackup() throws {
    let empty = try makeContext()
    try CategoryService(context: empty).seed()
    try empty.save()
    let data = try DataExport.jsonData(from: try DataExport.snapshot(of: empty))

    let context = try makeContext()
    try seedEverything(into: context)
    try DataImport.apply(try DataImport.validate(data), to: context)
    #expect(try context.fetchCount(FetchDescriptor<Budget>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<Expense>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<Runway.Category>()) == 7)
  }

  @Test("Every screenshot scenario's sample data exports a valid backup")
  func scenariosExportValidBackups() throws {
    let now = calendar.date(2026, 6, 10, 12)
    for scenario in ScreenshotScenario.allCases where scenario != .history500 {
      let context = try makeContext()
      try CategoryService(context: context).seed()
      try scenario.seed(into: context, now: now, calendar: calendar)
      let data = try DataExport.jsonData(from: try DataExport.snapshot(of: context, now: now))
      _ = try DataImport.validate(data)
    }
  }

  // MARK: - Rejections

  /// Encodes the mutated snapshot and checks that it's rejected with `error`, leaving a populated
  /// store untouched.
  private func expectRejected(
    _ error: DataImportError,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ mutate: (inout RunwaySnapshot) -> Void
  ) throws {
    var snapshot = try validSnapshot()
    mutate(&snapshot)
    let data = try DataExport.jsonData(from: snapshot)
    let context = try makeContext()
    try seedEverything(into: context)
    let before = try DataExport.snapshot(of: context, now: snapshot.exportedAt)

    #expect(throws: error, sourceLocation: sourceLocation) {
      try DataImport.validate(data)
    }
    #expect(try DataExport.snapshot(of: context, now: snapshot.exportedAt) == before)
    #expect(!context.hasChanges)
  }

  @Test("Import rejects other format versions")
  func rejectsVersion() throws {
    try expectRejected(.unsupportedVersion(2)) { $0.formatVersion = 2 }
    try expectRejected(.unsupportedVersion(0)) { $0.formatVersion = 0 }
    // A newer file reports its version even when the rest has a shape this version can't read.
    #expect(throws: DataImportError.unsupportedVersion(99)) {
      try DataImport.validate(Data(#"{"formatVersion": 99, "ledger": []}"#.utf8))
    }
  }

  @Test("Import rejects negative amounts where they can't occur")
  func rejectsNegativeAmounts() throws {
    try expectRejected(.negativeAmount("budget spendable")) {
      $0.budgets[0].spendablePerPeriodCents = -1
    }
    try expectRejected(.negativeAmount("budget savings")) { $0.budgets[0].savingsCents = -1 }
    try expectRejected(.negativeAmount("budget income")) { $0.budgets[0].incomeCents = -1 }
    try expectRejected(.negativeAmount("bill amount")) { $0.fixedBills[0].amountCents = -1 }
    try expectRejected(.negativeAmount("extra money amount")) { $0.extraMoney[0].amountCents = -1 }
    try expectRejected(.negativeAmount("bill payment amount")) { $0.billPayments[0].paidCents = -1 }
  }

  @Test("Import accepts refunds and other amounts that are legitimately negative")
  func acceptsLegitimateNegatives() throws {
    let snapshot = try validSnapshot()
    #expect(snapshot.expenses.contains { $0.amountCents < 0 })
    #expect(snapshot.amountChanges.contains { $0.previousAvailableCents < 0 })
    #expect(snapshot.billPayments.contains { $0.adjustmentCents < 0 })
    #expect(snapshot.billPayments.contains { $0.plannedCents < 0 })
    _ = try DataImport.validate(snapshot)
  }

  @Test("Import rejects references to records that don't exist")
  func rejectsDanglingReferences() throws {
    try expectRejected(.danglingReference("expense category")) { $0.expenses[0].categoryID = 999 }
    try expectRejected(.danglingReference("bill budget")) { $0.fixedBills[0].budgetID = 999 }
    try expectRejected(.danglingReference("bill payment bill")) { $0.billPayments[0].billID = 999 }
    try expectRejected(.danglingReference("bill payment budget")) {
      $0.billPayments[0].budgetID = 999
    }
    try expectRejected(.danglingReference("carryover change budget")) {
      $0.carryoverChanges[0].budgetID = 999
    }
    try expectRejected(.danglingReference("amount change budget")) {
      $0.amountChanges[0].budgetID = 999
    }
    try expectRejected(.danglingReference("schedule change budget")) {
      $0.scheduleChanges[0].budgetID = 999
    }
    try expectRejected(.danglingReference("extra money budget")) {
      $0.extraMoney[0].budgetID = 999
    }
  }

  @Test("Import rejects malformed JSON and files that aren't backups")
  func rejectsMalformed() throws {
    let context = try makeContext()
    try seedEverything(into: context)
    let before = try counts(in: context)
    let valid = try DataExport.jsonData(from: try validSnapshot())
    let inputs = [
      Data(),
      Data("not json".utf8),
      Data("[1, 2]".utf8),
      Data(valid.prefix(valid.count / 2)),
    ]
    for input in inputs {
      #expect(throws: DataImportError.malformed) {
        try DataImport.validate(input)
      }
    }
    #expect(try counts(in: context) == before)
  }

  @Test("Import rejects missing required fields and values of the wrong type")
  func rejectsMissingFields() throws {
    let data = try DataExport.jsonData(from: try validSnapshot())
    func mutated(_ change: (inout [String: Any]) -> Void) throws -> Data {
      var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
      change(&object)
      return try JSONSerialization.data(withJSONObject: object)
    }
    func firstExpenseChanged(_ change: (inout [String: Any]) -> Void) throws -> Data {
      try mutated { object in
        var expenses = object["expenses"] as! [[String: Any]]
        change(&expenses[0])
        object["expenses"] = expenses
      }
    }

    #expect(throws: DataImportError.missingField("formatVersion")) {
      try DataImport.validate(try mutated { $0["formatVersion"] = nil })
    }
    #expect(throws: DataImportError.missingField("budgets")) {
      try DataImport.validate(try mutated { $0["budgets"] = nil })
    }
    #expect(throws: DataImportError.missingField("amountCents")) {
      try DataImport.validate(try firstExpenseChanged { $0["amountCents"] = nil })
    }
    #expect(throws: DataImportError.missingField("amountCents")) {
      try DataImport.validate(try firstExpenseChanged { $0["amountCents"] = NSNull() })
    }
    #expect(throws: DataImportError.malformed) {
      try DataImport.validate(try firstExpenseChanged { $0["amountCents"] = "twelve" })
    }
    #expect(throws: DataImportError.malformed) {
      try DataImport.validate(try firstExpenseChanged { $0["amountCents"] = 12.5 })
    }
    #expect(throws: DataImportError.malformed) {
      try DataImport.validate(
        try mutated { object in
          var budgets = object["budgets"] as! [[String: Any]]
          budgets[0]["periodLength"] = "fortnightly"
          object["budgets"] = budgets
        }
      )
    }
  }

  @Test("Import rejects values the app could never have produced")
  func rejectsInvalidValues() throws {
    try expectRejected(.duplicateID("categories")) {
      $0.categories[1].id = $0.categories[0].id
    }
    try expectRejected(.duplicateID("expenses")) { $0.expenses[1].id = $0.expenses[0].id }
    try expectRejected(.invalidField("bill due day")) { $0.fixedBills[0].dueDay = 32 }
    try expectRejected(.invalidField("bill name")) { $0.fixedBills[0].name = "  " }
    try expectRejected(.invalidField("category name")) { $0.categories[0].name = "" }
    try expectRejected(.invalidField("the system category")) {
      for index in $0.categories.indices { $0.categories[index].isSystem = false }
    }
    try expectRejected(.invalidField("the system category")) {
      for index in $0.categories.indices { $0.categories[index].isSystem = true }
    }
    // These would overflow or stall the allowance engine.
    try expectRejected(.amountTooLarge("expense amount")) { $0.expenses[0].amountCents = .max }
    try expectRejected(.amountTooLarge("expense amount")) { $0.expenses[0].amountCents = .min }
    try expectRejected(.dateOutOfRange("expense date")) { $0.expenses[0].date = .distantFuture }
  }

  // MARK: - CSV

  @Test("CSV fields are quoted only when needed, with quotes doubled")
  func csvEscaping() {
    #expect(DataExport.csvField("") == "")
    #expect(DataExport.csvField("Lunch") == "Lunch")
    #expect(DataExport.csvField("Lunch, Sam") == "\"Lunch, Sam\"")
    #expect(DataExport.csvField("6\" sub") == "\"6\"\" sub\"")
    #expect(DataExport.csvField("\"") == "\"\"\"\"")
    #expect(DataExport.csvField("a\nb") == "\"a\nb\"")
    #expect(DataExport.csvField("a\rb") == "\"a\rb\"")
    // `\r\n` is a single Swift `Character`, so this catches a check for "\n" as a Character.
    #expect(DataExport.csvField("a\r\nb") == "\"a\r\nb\"")
  }

  @Test(
    "CSV text starting with a formula character gets a leading apostrophe",
    arguments: ["=", "+", "-", "@", "\t", "\r"]
  )
  func csvFormulaEscaping(lead: String) {
    let text = lead + "SUM(A1)"
    #expect(DataExport.csvText(text) == "'" + text)
  }

  @Test("CSV text escaping leaves other text alone and runs before quoting")
  func csvTextUntouched() {
    #expect(DataExport.csvText("") == "")
    #expect(DataExport.csvText("Lunch") == "Lunch")
    #expect(DataExport.csvText("Lunch = $5 - tip") == "Lunch = $5 - tip")
    #expect(DataExport.csvText("'quoted") == "'quoted")
    // `\r\n` is a single Swift `Character`, so this catches a check on the first Character.
    #expect(DataExport.csvText("\r\nnote") == "'\r\nnote")
    #expect(DataExport.csvField(DataExport.csvText("=A1,\"B\"")) == "\"'=A1,\"\"B\"\"\"")
  }

  @Test("The CSV escapes notes and category names but not amounts or dates")
  func csvDocumentEscaping() throws {
    let context = try makeContext()
    let service = CategoryService(context: context)
    try service.seed()
    let food = try #require(try service.categories().first { $0.name == "Food" })
    food.name = "@Food"
    try service.createExpense(
      amountCents: -1_250,
      note: "=HYPERLINK(\"http://example.com\")",
      date: calendar.date(2026, 6, 2, 12),
      category: food,
      now: calendar.date(2026, 6, 2, 13)
    )
    try service.createExpense(
      amountCents: 500,
      note: "Plain note",
      date: calendar.date(2026, 6, 3, 9),
      category: food,
      now: calendar.date(2026, 6, 3, 10)
    )
    try context.save()

    let csv = try DataExport.expensesCSV(in: context, timeZone: calendar.timeZone)
    #expect(
      csv == "date,amount,category,note,created_at\r\n"
        + "2026-06-02T12:00:00-05:00,-12.50,'@Food,"
        + "\"'=HYPERLINK(\"\"http://example.com\"\")\",2026-06-02T13:00:00-05:00\r\n"
        + "2026-06-03T09:00:00-05:00,5.00,'@Food,Plain note,2026-06-03T10:00:00-05:00\r\n"
    )
  }

  @Test("CSV amounts are plain dollars built from integer cents")
  func csvAmounts() {
    #expect(DataExport.csvAmount(cents: 0) == "0.00")
    #expect(DataExport.csvAmount(cents: 5) == "0.05")
    #expect(DataExport.csvAmount(cents: 1_250) == "12.50")
    #expect(DataExport.csvAmount(cents: -500) == "-5.00")
    #expect(DataExport.csvAmount(cents: -5) == "-0.05")
    #expect(DataExport.csvAmount(cents: 123_456_789) == "1234567.89")
  }

  @Test("The CSV has a header, then one row per expense, oldest first, with CRLF endings")
  func csvDocument() throws {
    let context = try makeContext()
    let service = CategoryService(context: context)
    try service.seed()
    let food = try #require(try service.categories().first { $0.name == "Food" })
    food.name = "Food, Drink"
    try service.createExpense(
      amountCents: -500,
      note: "Refund",
      date: calendar.date(2026, 6, 3, 9),
      category: food,
      now: calendar.date(2026, 6, 3, 10)
    )
    try service.createExpense(
      amountCents: 1_250,
      note: "Lunch \"with\" Sam\nand Alex",
      date: calendar.date(2026, 6, 2, 12),
      now: calendar.date(2026, 6, 2, 13)
    )
    try context.save()

    let csv = try DataExport.expensesCSV(in: context, timeZone: calendar.timeZone)
    #expect(
      csv == "date,amount,category,note,created_at\r\n"
        + "2026-06-02T12:00:00-05:00,12.50,Other,\"Lunch \"\"with\"\" Sam\nand Alex\","
        + "2026-06-02T13:00:00-05:00\r\n"
        + "2026-06-03T09:00:00-05:00,-5.00,\"Food, Drink\",Refund,2026-06-03T10:00:00-05:00\r\n"
    )
  }

  @Test("With no expenses the CSV is just the header")
  func csvEmpty() throws {
    let csv = try DataExport.expensesCSV(in: try makeContext(), timeZone: calendar.timeZone)
    #expect(csv == "date,amount,category,note,created_at\r\n")
  }

  // MARK: - Reset

  @Test("Deleting removes every model")
  func deleteAll() throws {
    let context = try makeContext()
    try seedEverything(into: context)
    try DataReset.deleteAll(in: context)
    try context.save()
    #expect(try counts(in: ModelContext(context.container)).allSatisfy { $0 == 0 })
  }

  @Test("Reset leaves only the default categories, ready for the first-launch flow")
  func reset() throws {
    let context = try makeContext()
    try seedEverything(into: context)
    try DataReset.reset(in: context)

    let loaded = ModelContext(context.container)
    #expect(try counts(in: loaded) == [0, 0, 0, 7, 0, 0, 0, 0, 0])
    let service = CategoryService(context: loaded)
    #expect(try service.categories().map(\.name) == CategoryService.defaultNames)
    try service.createExpense(amountCents: 100)
    try loaded.save()
    #expect(try loaded.fetch(FetchDescriptor<Expense>()).first?.category?.isSystem == true)
  }
}
