import Foundation
import os

/// Moves the store once from its old location to a new one. Run it before any container opens
/// either location.
///
/// The old store is counted from a scratch copy, then copied, and the copy must hold exactly the
/// same counts. Only then is a marker written next to the new store and completion recorded in
/// `defaults`, which stay readable without the App Group. Without either, the old store stays the
/// source of truth, so a failed or interrupted run just starts over. With them the new store is the
/// source of truth and is never overwritten.
///
/// The migration never deletes the old store; only `DataReset` does, when the user erases their
/// data. It's renamed to a dated backup, and only while it still matches the size and modification
/// date in the marker. A store that has changed since, as after a downgrade, is left alone.
struct StoreMigration {
  enum Outcome: Equatable {
    /// There was no old store, as on a fresh install.
    case nothingToMigrate
    case migrated
    /// An earlier run finished. Only retries backing up an unchanged old store it left behind.
    case alreadyMigrated
  }

  struct FileStamp: Codable, Equatable {
    let size: UInt64
    let modified: Date
  }

  /// What was migrated, as it was just before the copy.
  struct MigratedStore: Codable, Equatable {
    let store: FileStamp
    /// Writes can sit in the `-wal` file without changing the store file. `-shm` isn't recorded,
    /// because merely opening a store changes it.
    let wal: FileStamp?
    let counts: [String: Int]
    let backupName: String
  }

  struct Marker: Codable, Equatable {
    /// Nil when there was nothing to migrate.
    let migratedStore: MigratedStore?
  }

  private static let completedKey = "StoreMigration.completed"

  let oldStoreURL: URL
  let newStoreURL: URL
  let defaults: UserDefaults
  /// When the migration runs, which dates the backup's name.
  var now: Date = .now
  /// Per-model counts of the old store, without writing to it.
  var countOldStore: (URL) throws -> [String: Int] = RunwayModelContainer.readOnlyStoreCounts(at:)
  /// Per-model counts of the new store. Throws unless it opens.
  var countNewStore: (URL) throws -> [String: Int] = RunwayModelContainer.storeCounts(at:)

  static func isComplete(newStoreURL: URL) -> Bool {
    FileManager.default.fileExists(atPath: markerURL(for: newStoreURL).path)
  }

  /// Whether a migration finished on this install, whichever containers are reachable now.
  static func isRecordedComplete(in defaults: UserDefaults) -> Bool {
    defaults.bool(forKey: completedKey)
  }

  /// The marker's contents, or nil if it's missing or unreadable, in which case nothing is known
  /// about the old store and it must be left alone.
  static func marker(newStoreURL: URL) -> Marker? {
    guard let data = try? Data(contentsOf: markerURL(for: newStoreURL)) else { return nil }
    return try? JSONDecoder().decode(Marker.self, from: data)
  }

  /// The name the store gets when it's backed up at `date`. The sidecars and support directory
  /// follow it, so the backup still opens as a store.
  static func backupURL(for storeURL: URL, date: Date) -> URL {
    let timestamp = date.ISO8601Format().replacingOccurrences(of: ":", with: "")
    return storeURL.deletingLastPathComponent()
      .appending(path: "\(backupPrefix(for: storeURL))\(timestamp).\(storeURL.pathExtension)")
  }

  /// Every existing file a migration can leave at the old location: dated backups, including ones
  /// only partly moved, then the old store itself. The store file comes last, so a run that stops
  /// partway never leaves a stray `-wal` that a store created later would replay.
  static func leftovers(atOldStoreURL oldStoreURL: URL) throws -> [URL] {
    let fileManager = FileManager.default
    let directory = oldStoreURL.deletingLastPathComponent()
    guard fileManager.fileExists(atPath: directory.path) else { return [] }
    let prefix = backupPrefix(for: oldStoreURL)
    // The support directory's name starts with a dot.
    let backups = try fileManager.contentsOfDirectory(atPath: directory.path)
      .filter { $0.hasPrefix(prefix) || $0.hasPrefix(".\(prefix)") }
      .map { directory.appending(path: $0) }
    let oldFiles = files(of: oldStoreURL).reversed()
      .filter { fileManager.fileExists(atPath: $0.path) }
    return backups + oldFiles
  }

  /// On failure the old store is untouched and nothing is left at the new location, except a store
  /// from an earlier interrupted run if clearing it was what failed.
  ///
  /// Throws `RunwayStoreError.sharedStoreUnavailable` if a finished migration's store is gone from
  /// the new location. Starting over could replace the user's data with an older or empty store.
  @discardableResult
  func run() throws -> Outcome {
    if Self.isComplete(newStoreURL: newStoreURL) {
      // The record is missing if the last run stopped right after writing the marker.
      recordComplete()
      if let migratedStore = Self.marker(newStoreURL: newStoreURL)?.migratedStore {
        backUpOldStoreIfUnchanged(migratedStore)
      }
      return .alreadyMigrated
    }
    guard !Self.isRecordedComplete(in: defaults) else {
      throw RunwayStoreError.sharedStoreUnavailable
    }
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: newStoreURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    guard fileManager.fileExists(atPath: oldStoreURL.path) else {
      try writeMarker(Marker(migratedStore: nil))
      recordComplete()
      return .nothingToMigrate
    }
    let migratedStore: MigratedStore
    do {
      let counts = try countOldStore(oldStoreURL)
      migratedStore = MigratedStore(
        store: try Self.stamp(of: oldStoreURL),
        wal: try? Self.stamp(of: Self.walURL(of: oldStoreURL)),
        counts: counts,
        backupName: Self.backupURL(for: oldStoreURL, date: now).lastPathComponent
      )
      // Anything here came from an interrupted run; nothing opens it before the marker exists.
      try removeNewFiles()
      let copies = zip(Self.files(of: oldStoreURL), Self.files(of: newStoreURL))
      for (source, destination) in copies where fileManager.fileExists(atPath: source.path) {
        try fileManager.copyItem(at: source, to: destination)
      }
      let copiedCounts = try countNewStore(newStoreURL)
      guard copiedCounts == counts else {
        throw RunwayStoreError.migrationCountMismatch(expected: counts, found: copiedCounts)
      }
      try writeMarker(Marker(migratedStore: migratedStore))
    } catch {
      try? removeNewFiles()
      throw error
    }
    recordComplete()
    backUpOldStoreIfUnchanged(migratedStore)
    return .migrated
  }

  static func walURL(of storeURL: URL) -> URL {
    storeURL.deletingLastPathComponent().appending(path: "\(storeURL.lastPathComponent)-wal")
  }

  private static func backupPrefix(for storeURL: URL) -> String {
    "\(storeURL.deletingPathExtension().lastPathComponent)-premigration-"
  }

  /// The store, its SQLite sidecars, and Core Data's directory for externally stored attributes.
  static func files(of storeURL: URL) -> [URL] {
    let directory = storeURL.deletingLastPathComponent()
    let name = storeURL.lastPathComponent
    let stem = storeURL.deletingPathExtension().lastPathComponent
    return [
      storeURL,
      walURL(of: storeURL),
      directory.appending(path: "\(name)-shm"),
      directory.appending(path: ".\(stem)_SUPPORT"),
    ]
  }

  private static func markerURL(for storeURL: URL) -> URL {
    storeURL.deletingLastPathComponent().appending(path: "\(storeURL.lastPathComponent).migrated")
  }

  private static func stamp(of url: URL) throws -> FileStamp {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard
      let size = attributes[.size] as? UInt64,
      let modified = attributes[.modificationDate] as? Date
    else {
      throw CocoaError(.fileReadUnknown)
    }
    return FileStamp(size: size, modified: modified)
  }

  private func writeMarker(_ marker: Marker) throws {
    let data = try JSONEncoder().encode(marker)
    try data.write(to: Self.markerURL(for: newStoreURL), options: .atomic)
  }

  private func recordComplete() {
    defaults.set(true, forKey: Self.completedKey)
  }

  private func removeNewFiles() throws {
    let fileManager = FileManager.default
    for file in Self.files(of: newStoreURL) where fileManager.fileExists(atPath: file.path) {
      try fileManager.removeItem(at: file)
    }
  }

  /// A failure here doesn't fail the migration, because the new store is already good. The next
  /// launch tries again.
  ///
  /// The store file moves last, so a run that stops partway still leaves it to match on the next
  /// launch, and never leaves a stray `-wal` that a store created later would replay. That's why a
  /// missing `-wal` still counts as unchanged: a real write that removed it changes the store file.
  private func backUpOldStoreIfUnchanged(_ migratedStore: MigratedStore) {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: oldStoreURL.path) else { return }
    let wal = try? Self.stamp(of: Self.walURL(of: oldStoreURL))
    guard
      (try? Self.stamp(of: oldStoreURL)) == migratedStore.store,
      wal == nil || wal == migratedStore.wal
    else {
      RunwayModelContainer.logger.notice(
        "The store at the old location changed after the migration; leaving it in place"
      )
      return
    }
    let backupURL = oldStoreURL.deletingLastPathComponent()
      .appending(path: migratedStore.backupName)
    let moves = Array(zip(Self.files(of: oldStoreURL), Self.files(of: backupURL))).reversed()
    for (source, destination) in moves where fileManager.fileExists(atPath: source.path) {
      do {
        try fileManager.moveItem(at: source, to: destination)
      } catch {
        let reason = String(describing: error)
        RunwayModelContainer.logger.error(
          "Couldn't back up the old store: \(reason, privacy: .public)"
        )
        return
      }
    }
  }
}
