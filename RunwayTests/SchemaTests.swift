import Foundation
import SwiftData
import Testing

@testable import Runway

struct SchemaTests {
  @Test("Current schema is version 2.0.0")
  func schemaVersion() {
    #expect(RunwaySchemaV2.versionIdentifier == Schema.Version(2, 0, 0))
    #expect(RunwaySchemaV1.versionIdentifier == Schema.Version(1, 1, 0))
    #expect(RunwaySchemaV2.models.count == 10)
    let models = RunwaySchemaV2.models.map { ObjectIdentifier($0) }
    #expect(models.contains(ObjectIdentifier(CarryoverChange.self)))
    // Mid-period budget changes (LIB-435).
    #expect(models.contains(ObjectIdentifier(AmountChange.self)))
    #expect(models.contains(ObjectIdentifier(ScheduleChange.self)))
    #expect(models.contains(ObjectIdentifier(ExtraMoney.self)))
    #expect(models.contains(ObjectIdentifier(BillPayment.self)))
    // Credit cards (LIB-441).
    #expect(models.contains(ObjectIdentifier(CreditCard.self)))
  }

  @Test("Migration plan retains every shipped schema with lightweight stages between them")
  func migrationPlan() {
    let schemas = RunwayMigrationPlan.schemas.map { ObjectIdentifier($0) }
    #expect(
      schemas == [
        ObjectIdentifier(RunwaySchemaV1Original.self), ObjectIdentifier(RunwaySchemaV1.self),
        ObjectIdentifier(RunwaySchemaV2.self),
      ]
    )
    #expect(RunwayMigrationPlan.stages.count == 2)
  }

  @Test("Every money attribute is stored as integer cents, never floating point")
  func moneyAttributesAreIntegers() {
    let schema = Schema(versionedSchema: RunwaySchemaV2.self)
    #expect(schema.entities.count == 10)

    var centsAttributes: Set<String> = []
    for entity in schema.entities {
      for attribute in entity.attributes {
        let typeName = String(describing: attribute.valueType)
        let label = "\(entity.name).\(attribute.name): \(typeName)"
        #expect(!typeName.contains("Double"), "\(label)")
        #expect(!typeName.contains("Float"), "\(label)")
        if attribute.name.hasSuffix("Cents") {
          centsAttributes.insert(attribute.name)
          #expect(typeName == "Int" || typeName == "Optional<Int>", "\(label)")
        }
      }
    }
    #expect(
      centsAttributes == [
        "spendablePerPeriodCents",
        "incomeCents",
        "savingsCents",
        "amountCents",
        "previousAvailableCents",
        "plannedCents",
        "paidCents",
        "adjustmentCents",
        "statementBalanceCents",
        "currentBalanceCents",
      ]
    )
  }

  @Test("A 1.1.0 on-disk store migrates with its values intact, no cards, and no payments")
  func migrateV1Store() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("Runway.store")
    let calendar = Calendar.gregorian("America/Chicago")
    let start = calendar.date(2026, 6, 1)
    do {
      let schema = Schema(versionedSchema: RunwaySchemaV1.self)
      let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
      let container = try ModelContainer(for: schema, configurations: [configuration])
      let context = ModelContext(container)
      let budget = RunwaySchemaV1.Budget(
        periodStart: start,
        spendablePerPeriodCents: 100_000,
        timeZoneIdentifier: "America/Chicago"
      )
      context.insert(budget)
      let extra = RunwaySchemaV1.ExtraMoney(amountCents: 2_500, note: "Gift", date: start)
      context.insert(extra)
      budget.extraMoney.append(extra)
      let category = RunwaySchemaV1.Category(
        name: "Food",
        symbol: "fork.knife",
        colorHex: "#FF9500"
      )
      context.insert(category)
      #if DEBUG
        let expense = ExpenseCreationGuard.$isAuthorized.withValue(true) {
          RunwaySchemaV1.Expense(amountCents: 1_000, note: "Lunch", date: start)
        }
      #else
        let expense = RunwaySchemaV1.Expense(amountCents: 1_000, note: "Lunch", date: start)
      #endif
      context.insert(expense)
      expense.category = category
      try context.save()
    }
    let context = ModelContext(try RunwayModelContainer.make(url: url))
    let budget = try #require(try context.fetch(FetchDescriptor<Budget>()).first)
    #expect(budget.spendablePerPeriodCents == 100_000)
    #expect(budget.timeZoneIdentifier == "America/Chicago")
    #expect(budget.extraMoney.map(\.amountCents) == [2_500])
    let expense = try #require(try context.fetch(FetchDescriptor<Expense>()).first)
    #expect(expense.amountCents == 1_000)
    #expect(expense.note == "Lunch")
    #expect(expense.category?.name == "Food")
    #expect(!expense.isCardPayment)
    #expect(expense.creditCard == nil)
    #expect(try context.fetchCount(FetchDescriptor<CreditCard>()) == 0)
  }

  @Test("An original on-disk store migrates with its values and relationships intact")
  func migrateOriginalStore() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("Runway.store")
    let calendar = Calendar.gregorian("America/Chicago")
    let start = calendar.date(2026, 6, 1)
    do {
      let schema = Schema(versionedSchema: RunwaySchemaV1Original.self)
      let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
      let container = try ModelContainer(for: schema, configurations: [configuration])
      let context = ModelContext(container)
      let budget = RunwaySchemaV1Original.Budget(
        periodLength: .weekly,
        periodStart: start,
        spendablePerPeriodCents: 100_000,
        savingsCents: 5_000,
        carryoverEnabled: false
      )
      context.insert(budget)
      let bill = RunwaySchemaV1Original.FixedBill(name: "Rent", amountCents: 30_000)
      context.insert(bill)
      budget.fixedBills.append(bill)
      let category = RunwaySchemaV1Original.Category(
        name: "Food",
        symbol: "fork.knife",
        colorHex: "#FF9500"
      )
      context.insert(category)
      #if DEBUG
        let expense = ExpenseCreationGuard.$isAuthorized.withValue(true) {
          RunwaySchemaV1Original.Expense(amountCents: 1_000, date: start)
        }
      #else
        let expense = RunwaySchemaV1Original.Expense(amountCents: 1_000, date: start)
      #endif
      context.insert(expense)
      expense.category = category
      let change = RunwaySchemaV1Original.CarryoverChange(
        enabled: false,
        previousEnabled: true,
        effectiveAt: calendar.date(2026, 6, 8)
      )
      context.insert(change)
      budget.carryoverChanges.append(change)
      try context.save()
    }
    let container = try RunwayModelContainer.make(url: url)
    let context = ModelContext(container)
    let budget = try #require(try context.fetch(FetchDescriptor<Budget>()).first)
    #expect(budget.periodStart == start)
    #expect(budget.availablePerPeriodCents == 65_000)
    #expect(!budget.carryoverEnabled)
    #expect(budget.fixedBills.first?.budget === budget)
    #expect(budget.carryoverChanges.first?.previousEnabled == true)
    #expect(budget.timeZoneIdentifier.isEmpty)
    #expect(budget.amountChanges.isEmpty && budget.scheduleChanges.isEmpty)
    #expect(budget.extraMoney.isEmpty && budget.billPayments.isEmpty)
    let expense = try #require(try context.fetch(FetchDescriptor<Expense>()).first)
    #expect(expense.amountCents == 1_000)
    #expect(expense.category?.name == "Food")
  }
}
