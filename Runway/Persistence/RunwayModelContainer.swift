import Foundation
import SwiftData

/// Builds the app's SwiftData container. Data stays on device; CloudKit sync is off.
enum RunwayModelContainer {
  static func make(inMemory: Bool) throws -> ModelContainer {
    let schema = Schema(versionedSchema: RunwaySchemaV1.self)
    // Give each in-memory container its own store so parallel tests never share data.
    let name: String? = inMemory ? "Runway-\(UUID().uuidString)" : nil
    let configuration = ModelConfiguration(
      name,
      schema: schema,
      isStoredInMemoryOnly: inMemory,
      cloudKitDatabase: .none
    )
    return try ModelContainer(
      for: schema,
      migrationPlan: RunwayMigrationPlan.self,
      configurations: [configuration]
    )
  }
}
