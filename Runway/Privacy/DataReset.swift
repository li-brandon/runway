import Foundation
import SwiftData

enum DataResetError: LocalizedError, Equatable {
  case unsavedChanges

  var errorDescription: String? {
    switch self {
    case .unsavedChanges:
      "Runway is still saving your latest changes. Try resetting again in a moment."
    }
  }
}

/// Erases the store. Preferences like the app lock stay as they are.
enum DataReset {
  /// Marks every model in the current schema for deletion, without saving. Walks the schema's own
  /// list so a new model can't be missed. Deletes one by one rather than in a batch, so the
  /// deletes stay pending in the context until a save, and discarding the context undoes them.
  static func deleteAll(in context: ModelContext) throws {
    for model in RunwaySchemaV1.models {
      try deleteAll(of: model, in: context)
    }
  }

  /// Returns the app to its first-launch state in a single save: no data except the default
  /// categories, which the app needs to log expenses. The work is staged in a separate scratch
  /// context on the same container, so a failure just discards that context and neither the store
  /// nor `context` changes. Rolling back staged deletes and inserts in place traps in SwiftData, so
  /// there is deliberately no rollback here. Unsaved changes in `context` throw before anything is
  /// staged. `save` replaces the scratch context's save so tests can fail it.
  static func reset(
    in context: ModelContext,
    save: ((ModelContext) throws -> Void)? = nil
  ) throws {
    guard !context.hasChanges else { throw DataResetError.unsavedChanges }
    let scratch = ModelContext(context.container)
    scratch.autosaveEnabled = false
    try deleteAll(in: scratch)
    try CategoryService(context: scratch).seed()
    if let save {
      try save(scratch)
    } else {
      try scratch.save()
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
