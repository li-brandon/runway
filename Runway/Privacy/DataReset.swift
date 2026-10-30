import Foundation
import SwiftData

/// Erases the store. Preferences like the app lock stay as they are.
enum DataReset {
  /// Marks every model in the current schema for deletion, without saving. Walks the schema's own
  /// list so a new model can't be missed. Deletes one by one rather than in a batch, so the
  /// deletes stay pending in the context until a save and a rollback can still undo them.
  static func deleteAll(in context: ModelContext) throws {
    for model in RunwaySchemaV1.models {
      try deleteAll(of: model, in: context)
    }
  }

  /// Returns the app to its first-launch state: no data except the default categories, which the
  /// app needs to log expenses. If deleting fails, nothing changes. If only the second save
  /// fails, the defaults come back through `CategoryService.seed` at the next launch.
  static func reset(in context: ModelContext) throws {
    do {
      try deleteAll(in: context)
      try context.save()
    } catch {
      context.rollback()
      throw error
    }
    do {
      try CategoryService(context: context).seed()
      try context.save()
    } catch {
      context.rollback()
    }
  }

  private static func deleteAll<M: PersistentModel>(
    of type: M.Type,
    in context: ModelContext
  ) throws {
    for model in try context.fetch(FetchDescriptor<M>()) {
      context.delete(model)
    }
  }
}
