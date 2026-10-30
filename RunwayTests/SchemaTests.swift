import Foundation
import SwiftData
import Testing

@testable import Runway

struct SchemaTests {
  @Test("Current schema is version 1.0.0")
  func schemaVersion() {
    #expect(RunwaySchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
    #expect(RunwaySchemaV1.models.count == 9)
    let models = RunwaySchemaV1.models.map { ObjectIdentifier($0) }
    #expect(models.contains(ObjectIdentifier(CarryoverChange.self)))
    // Mid-period budget changes (LIB-435). V1 hasn't shipped, so they're added in place.
    #expect(models.contains(ObjectIdentifier(AmountChange.self)))
    #expect(models.contains(ObjectIdentifier(ScheduleChange.self)))
    #expect(models.contains(ObjectIdentifier(ExtraMoney.self)))
    #expect(models.contains(ObjectIdentifier(BillPayment.self)))
  }

  @Test("Migration plan lists V1 and has no stages yet")
  func migrationPlan() {
    let schemas = RunwayMigrationPlan.schemas.map { ObjectIdentifier($0) }
    #expect(schemas == [ObjectIdentifier(RunwaySchemaV1.self)])
    #expect(RunwayMigrationPlan.stages.isEmpty)
  }

  @Test("Every money attribute is stored as integer cents, never floating point")
  func moneyAttributesAreIntegers() {
    let schema = Schema(versionedSchema: RunwaySchemaV1.self)
    #expect(schema.entities.count == 9)

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
      ]
    )
  }
}
