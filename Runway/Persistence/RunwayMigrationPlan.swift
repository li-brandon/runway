import SwiftData

/// Ordered list of every schema version Runway has shipped, plus the stages between them.
enum RunwayMigrationPlan: SchemaMigrationPlan {
  static var schemas: [any VersionedSchema.Type] {
    [RunwaySchemaV1.self]
  }

  static var stages: [MigrationStage] {
    []
  }
}
