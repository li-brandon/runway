import Foundation
import os

/// Moves the store once from its old location to a new one, without opening the old store. Run it
/// before any container opens either location.
///
/// A marker file next to the new store records that the move is finished, and it's written only
/// after the new store has opened. Without the marker the old store stays the source of truth, so
/// an interrupted run just starts over. With it the new store is the source of truth and is never
/// overwritten.
struct StoreMigration {
  enum Outcome: Equatable {
    /// There was no old store, as on a fresh install.
    case nothingToMigrate
    case migrated
    /// An earlier run finished. Only retries removing any old files that one left behind.
    case alreadyMigrated
  }

  let oldStoreURL: URL
  let newStoreURL: URL
  /// Throws unless the store at the given URL opens.
  var verify: (URL) throws -> Void = RunwayModelContainer.verifyStore(at:)

  static func isComplete(newStoreURL: URL) -> Bool {
    FileManager.default.fileExists(atPath: markerURL(for: newStoreURL).path)
  }

  /// On failure the old store is untouched and nothing is left at the new location, except a store
  /// from an earlier interrupted run if clearing it was what failed.
  @discardableResult
  func run() throws -> Outcome {
    if Self.isComplete(newStoreURL: newStoreURL) {
      removeOldFiles()
      return .alreadyMigrated
    }
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: newStoreURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    guard fileManager.fileExists(atPath: oldStoreURL.path) else {
      try writeMarker()
      return .nothingToMigrate
    }
    do {
      // Anything here came from an interrupted run; nothing opens it before the marker exists.
      try removeNewFiles()
      let copies = zip(Self.files(of: oldStoreURL), Self.files(of: newStoreURL))
      for (source, destination) in copies where fileManager.fileExists(atPath: source.path) {
        try fileManager.copyItem(at: source, to: destination)
      }
      try verify(newStoreURL)
      try writeMarker()
    } catch {
      try? removeNewFiles()
      throw error
    }
    removeOldFiles()
    return .migrated
  }

  /// The store, its SQLite sidecars, and Core Data's directory for externally stored attributes.
  private static func files(of storeURL: URL) -> [URL] {
    let directory = storeURL.deletingLastPathComponent()
    let name = storeURL.lastPathComponent
    let stem = storeURL.deletingPathExtension().lastPathComponent
    return [
      storeURL,
      directory.appending(path: "\(name)-wal"),
      directory.appending(path: "\(name)-shm"),
      directory.appending(path: ".\(stem)_SUPPORT"),
    ]
  }

  private static func markerURL(for storeURL: URL) -> URL {
    storeURL.deletingLastPathComponent().appending(path: "\(storeURL.lastPathComponent).migrated")
  }

  private func writeMarker() throws {
    try Data().write(to: Self.markerURL(for: newStoreURL), options: .atomic)
  }

  private func removeNewFiles() throws {
    let fileManager = FileManager.default
    for file in Self.files(of: newStoreURL) where fileManager.fileExists(atPath: file.path) {
      try fileManager.removeItem(at: file)
    }
  }

  /// A failure here doesn't fail the migration, because the new store is already good. The next
  /// launch tries again.
  private func removeOldFiles() {
    let fileManager = FileManager.default
    for file in Self.files(of: oldStoreURL) where fileManager.fileExists(atPath: file.path) {
      do {
        try fileManager.removeItem(at: file)
      } catch {
        let reason = String(describing: error)
        RunwayModelContainer.logger.error(
          "Couldn't remove the old store file: \(reason, privacy: .public)"
        )
      }
    }
  }
}
