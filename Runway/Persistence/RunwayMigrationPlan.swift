import SwiftData

/// Ordered list of every schema version Runway has shipped, plus the stages between them.
enum RunwayMigrationPlan: SchemaMigrationPlan {
  static var schemas: [any VersionedSchema.Type] {
    [RunwaySchemaV1Original.self, RunwaySchemaV1.self, RunwaySchemaV2.self]
  }

  static var stages: [MigrationStage] {
    [
      .lightweight(fromVersion: RunwaySchemaV1Original.self, toVersion: RunwaySchemaV1.self),
      .lightweight(fromVersion: RunwaySchemaV1.self, toVersion: RunwaySchemaV2.self),
    ]
  }
}
