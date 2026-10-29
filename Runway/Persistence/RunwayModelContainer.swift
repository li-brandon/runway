import Foundation
import SwiftData

/// Builds the app's SwiftData container. Data stays on device; CloudKit sync is off.
enum RunwayModelContainer {
  /// The app's default on-disk store, or a fresh in-memory store (tests, screenshots).
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
    return try make(schema: schema, configuration: configuration)
  }

  /// An on-disk store at `url`. Tests use it to simulate a relaunch by opening a second
  /// container on the same file.
  static func make(url: URL) throws -> ModelContainer {
    let schema = Schema(versionedSchema: RunwaySchemaV1.self)
    let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
    return try make(schema: schema, configuration: configuration)
  }

  private static func make(
    schema: Schema,
    configuration: ModelConfiguration
  ) throws -> ModelContainer {
    try ModelContainer(
      for: schema,
      migrationPlan: RunwayMigrationPlan.self,
      configurations: [configuration]
    )
  }
}
