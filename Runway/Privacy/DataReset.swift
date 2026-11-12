import Foundation
import SwiftData
import os

enum DataResetError: LocalizedError, Equatable {
  case unsavedChanges
  /// The store was reset, but files from before the App Group move couldn't all be deleted.
  case leftoverFilesRemain

  var errorDescription: String? {
    switch self {
    case .unsavedChanges:
      "Runway is still saving your latest changes. Try resetting again in a moment."
    case .leftoverFilesRemain:
      "Your data was reset, but some old files couldn't be erased. Try resetting again."
    }
  }
}

/// Erases the store and any older copies of it. Preferences like the app lock stay as they are.
enum DataReset {
  /// Marks every model in the current schema for deletion, without saving. Walks the schema's own
  /// list so a new model can't be missed. Deletes one by one rather than in a batch, so the
  /// deletes stay pending in the context until a save, and discarding the context undoes them.
  static func deleteAll(in context: ModelContext) throws {
    for model in RunwaySchemaV2.models {
      try deleteAll(of: model, in: context)
    }
  }

  /// Returns the app to its first-launch state in a single save: no data except the default
  /// categories, which the app needs to log expenses. The work is staged in a separate scratch
  /// context on the same container, so a failure just discards that context and neither the store
  /// nor `context` changes. Rolling back staged deletes and inserts in place traps in SwiftData, so
  /// there is deliberately no rollback here. Unsaved changes in `context` throw before anything is
  /// staged. `save` replaces the scratch context's save so tests can fail it.
  ///
  /// Only after that save, deletes the migration's backups and any store left at `legacyStoreURL`,
  /// so a failed reset still loses nothing. Throws `leftoverFilesRemain` if any of them stay, in
  /// which case the reset itself has happened and running it again retries the deletes.
  static func reset(
    in context: ModelContext,
    legacyStoreURL: URL = RunwayModelContainer.legacyStoreURL,
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
    try removeLeftovers(ofLegacyStoreAt: legacyStoreURL, keepingStoresOf: context.container)
  }

  /// The store `container` has open is never deleted, and that can be the one at the legacy URL,
  /// which is where the app runs until a migration succeeds. An in-memory container (tests,
  /// screenshots) leaves the disk alone, since whatever is there isn't what was just reset.
  private static func removeLeftovers(
    ofLegacyStoreAt legacyStoreURL: URL,
    keepingStoresOf container: ModelContainer
  ) throws {
    let configurations = container.configurations
    guard !configurations.contains(where: \.isStoredInMemoryOnly) else { return }
    let liveFiles = Set(
      configurations.flatMap { StoreMigration.files(of: $0.url) }.map(canonicalPath(of:))
    )
    var allRemoved = true
    do {
      let leftovers = try StoreMigration.leftovers(atOldStoreURL: legacyStoreURL)
      for file in leftovers where !liveFiles.contains(canonicalPath(of: file)) {
        do {
          try FileManager.default.removeItem(at: file)
        } catch {
          allRemoved = false
          logRemovalFailure(error)
        }
      }
    } catch {
      allRemoved = false
      logRemovalFailure(error)
    }
    guard allRemoved else { throw DataResetError.leftoverFilesRemain }
  }

  private static func logRemovalFailure(_ error: any Error) {
    let reason = String(describing: error)
    RunwayModelContainer.logger.error(
      "Couldn't delete a leftover store file: \(reason, privacy: .public)"
    )
  }

  /// Resolves only the directory, which exists, so a sidecar compares the same whether or not it's
  /// on disk yet.
  private static func canonicalPath(of url: URL) -> String {
    url.deletingLastPathComponent().resolvingSymlinksInPath()
      .appending(path: url.lastPathComponent).path
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
