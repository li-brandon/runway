import Foundation
import SQLite3
import os

/// Moves the store once from its old location to a new one. Run it before any container opens
/// either location.
///
/// The old store is opened read-only and counted, then copied, and the copy must hold exactly the
/// same counts. Only then is a marker written next to the new store and completion recorded in
/// `defaults`, which stay readable without the App Group. Without either, the old store stays the
/// source of truth, so a failed or interrupted run just starts over. With them the new store is the
/// source of truth and is never overwritten.
///
/// The migration never deletes the old store; only `DataReset` does, when the user erases their
/// data. It's renamed to a dated backup, and only while it still matches the size and modification
/// date in the marker. A store that has changed since, as after a downgrade, is left alone.
///
/// SQLite closes a store some time after its container is released, and renaming or deleting files
/// a connection still has open breaks the next open with `SQLITE_IOERR_VNODE`. So no store file
/// moves or is deleted until every connection to that store has closed.
///
/// `run()` is synchronous, and the app calls it on the main thread at launch. Waiting for
/// connections to close is what can take long, so all of a run's waits share one deadline,
/// `closeBudget` after it starts. With the defaults, a run blocks its thread for at most 10 seconds
/// waiting, plus one last non-blocking check in each of its at most three waits. Counting and
/// copying the store aren't covered.
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
  private static let sqliteHeader = Data("SQLite format 3\0".utf8)

  let oldStoreURL: URL
  let newStoreURL: URL
  let defaults: UserDefaults
  /// When the migration runs, which dates the backup's name.
  var now: Date = .now
  /// Per-model counts of the old store, without writing to it.
  var countOldStore: (URL) throws -> [String: Int] = RunwayModelContainer.readOnlyStoreCounts(at:)
  /// Per-model counts of the new store. Throws unless it opens.
  var countNewStore: (URL) throws -> [String: Int] = RunwayModelContainer.storeCounts(at:)
  /// How long to wait for a store's connections to close before leaving its files where they are.
  var closeTimeout: TimeInterval = 5
  /// The longest a whole run waits for connections to close, however many stores it waits for.
  var closeBudget: TimeInterval = 10

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

  /// On failure the old store's data is untouched, though closing it can merge its `-wal` into the
  /// store file. Nothing is left at the new location, except a store from an earlier interrupted
  /// run if clearing it was what failed, or a copy that was still open after `closeTimeout` or once
  /// `closeBudget` ran out. The next run clears either.
  ///
  /// Throws `RunwayStoreError.sharedStoreUnavailable` if a finished migration's store is gone from
  /// the new location. Starting over could replace the user's data with an older or empty store.
  @discardableResult
  func run() throws -> Outcome {
    // A monotonic clock, so a change to the wall clock can't stretch or cut short the waits.
    let closeDeadline = ContinuousClock.now.advanced(by: .seconds(closeBudget))
    if Self.isComplete(newStoreURL: newStoreURL) {
      // The record is missing if the last run stopped right after writing the marker.
      recordComplete()
      if let migratedStore = Self.marker(newStoreURL: newStoreURL)?.migratedStore {
        backUpOldStoreIfUnchanged(migratedStore, closeDeadline: closeDeadline)
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
      let counts = try autoreleasepool { try countOldStore(oldStoreURL) }
      // Stamped once every connection has closed and the `-wal` is merged, so neither that merge
      // nor a later check for connections can look like a write. A connection still open after
      // `closeTimeout` can change the store when it closes, which only leaves the old store in
      // place.
      waitUntilClosed(oldStoreURL, closeDeadline: closeDeadline)
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
      let copiedCounts = try autoreleasepool { try countNewStore(newStoreURL) }
      guard copiedCounts == counts else {
        throw RunwayStoreError.migrationCountMismatch(expected: counts, found: copiedCounts)
      }
      waitUntilClosed(newStoreURL, closeDeadline: closeDeadline)
      try writeMarker(Marker(migratedStore: migratedStore))
    } catch {
      removeNewFilesOnceClosed(closeDeadline: closeDeadline)
      throw error
    }
    recordComplete()
    backUpOldStoreIfUnchanged(migratedStore, closeDeadline: closeDeadline)
    return .migrated
  }

  private static func walURL(of storeURL: URL) -> URL {
    storeURL.deletingLastPathComponent().appending(path: "\(storeURL.lastPathComponent)-wal")
  }

  private static func shmURL(of storeURL: URL) -> URL {
    storeURL.deletingLastPathComponent().appending(path: "\(storeURL.lastPathComponent)-shm")
  }

  private static func backupPrefix(for storeURL: URL) -> String {
    "\(storeURL.deletingPathExtension().lastPathComponent)-premigration-"
  }

  /// The store, its SQLite sidecars, and Core Data's directory for externally stored attributes.
  static func files(of storeURL: URL) -> [URL] {
    let directory = storeURL.deletingLastPathComponent()
    let stem = storeURL.deletingPathExtension().lastPathComponent
    return [
      storeURL,
      walURL(of: storeURL),
      shmURL(of: storeURL),
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

  /// Whether every connection to the store closed within `closeTimeout`, and before
  /// `closeDeadline`, the end of the run's `closeBudget`.
  @discardableResult
  private func waitUntilClosed(_ storeURL: URL, closeDeadline: ContinuousClock.Instant) -> Bool {
    let deadline = min(ContinuousClock.now.advanced(by: .seconds(closeTimeout)), closeDeadline)
    guard Self.waitUntilClosed(storeURL, deadline: deadline) else {
      RunwayModelContainer.logger.notice("A store was still open after waiting for it to close")
      return false
    }
    return true
  }

  /// Whether every connection to the store closed by `deadline`. Once they have, the `-wal` is
  /// merged into the store file, and any sidecars left are empty or transient. Checking can leave
  /// or recreate them, but doesn't change the store file once it's merged. Checks at least once,
  /// even once `deadline` has passed.
  static func waitUntilClosed(_ storeURL: URL, deadline: ContinuousClock.Instant) -> Bool {
    while hasOpenConnection(to: storeURL) {
      guard ContinuousClock.now < deadline else { return false }
      pauseBetweenChecks()
    }
    return true
  }

  /// Runs the current run loop between checks rather than sleeping. A released container can
  /// finish closing with work queued to the thread that's waiting, as on the main thread at launch,
  /// and sleeping through it would keep the store open until the deadline. A run loop with nothing
  /// to run returns at once, so the rest of the pause is slept.
  private static func pauseBetweenChecks() {
    let end = Date(timeIntervalSinceNow: 0.02)
    while Date() < end {
      guard RunLoop.current.run(mode: .default, before: end) else {
        Thread.sleep(until: end)
        return
      }
    }
  }

  /// Every open connection holds a shared lock on a WAL store, even when idle, so an exclusive
  /// lock is refused until they've all closed. SQLite applies that between connections in this
  /// process as well as other processes.
  ///
  /// Holding that lock, it also empties the `-wal`, because closing alone can leave one behind with
  /// a size and date of its own. A checkpoint that couldn't empty it counts as still open.
  ///
  /// Only opens real SQLite stores, because closing would discard a `-wal` it can't apply. A store
  /// that can't be opened for any other reason has no sign of a connection, so reports none.
  private static func hasOpenConnection(to storeURL: URL) -> Bool {
    guard isSQLiteStore(storeURL) else { return false }
    var connection: OpaquePointer?
    defer { sqlite3_close_v2(connection) }
    let opened = sqlite3_open_v2(storeURL.path, &connection, SQLITE_OPEN_READWRITE, nil)
    guard opened == SQLITE_OK else { return false }
    // `BEGIN EXCLUSIVE` wouldn't do: in WAL mode it doesn't exclude readers.
    let locked = sqlite3_exec(
      connection,
      "PRAGMA locking_mode=EXCLUSIVE; SELECT count(*) FROM sqlite_master;",
      nil,
      nil,
      nil
    )
    guard locked == SQLITE_OK else { return locked == SQLITE_BUSY || locked == SQLITE_LOCKED }
    // Unlike `PRAGMA wal_checkpoint`, which reports a blocked checkpoint as a row, this returns it.
    let checkpointed = sqlite3_wal_checkpoint_v2(
      connection,
      nil,
      SQLITE_CHECKPOINT_TRUNCATE,
      nil,
      nil
    )
    return checkpointed == SQLITE_BUSY || checkpointed == SQLITE_LOCKED
  }

  /// Closes the file before SQLite opens the store, so the probe never holds a descriptor of its own
  /// across the check.
  private static func isSQLiteStore(_ storeURL: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: storeURL) else { return false }
    defer { try? handle.close() }
    return (try? handle.read(upToCount: sqliteHeader.count)) == sqliteHeader
  }

  /// An empty `-wal` counts as unchanged whatever its date: it holds no writes, and just opening
  /// the store can recreate it.
  private func isUnchanged(_ migratedStore: MigratedStore) -> Bool {
    let wal = try? Self.stamp(of: Self.walURL(of: oldStoreURL))
    return (try? Self.stamp(of: oldStoreURL)) == migratedStore.store
      && (wal == nil || wal?.size == 0 || wal == migratedStore.wal)
  }

  /// Whether a closed old store's sidecar holds nothing worth keeping: `-shm` is rebuilt on open,
  /// and an empty `-wal` has no writes.
  private func isDisposableSidecar(_ file: URL) -> Bool {
    file == Self.shmURL(of: oldStoreURL)
      || (file == Self.walURL(of: oldStoreURL) && (try? Self.stamp(of: file))?.size == 0)
  }

  /// A file that a closing connection deletes between the check and the removal is already gone,
  /// so it doesn't stop the files after it from being removed.
  private func removeNewFiles() throws {
    let fileManager = FileManager.default
    for file in Self.files(of: newStoreURL) where fileManager.fileExists(atPath: file.path) {
      do {
        try fileManager.removeItem(at: file)
      } catch CocoaError.fileNoSuchFile {}
    }
  }

  /// Clears the new location after a failed run, before `run()` throws. A container that counted
  /// the copy can still be closing once one check finds the store closed, and closing can recreate
  /// a sidecar, so this checks again until nothing is left, within `closeTimeout` and the run's
  /// `closeBudget`. A store still open then is left for the next run to clear.
  private func removeNewFilesOnceClosed(closeDeadline: ContinuousClock.Instant) {
    let fileManager = FileManager.default
    let deadline = min(ContinuousClock.now.advanced(by: .seconds(closeTimeout)), closeDeadline)
    while true {
      guard Self.waitUntilClosed(newStoreURL, deadline: deadline) else {
        RunwayModelContainer.logger.notice("A store was still open after waiting for it to close")
        return
      }
      try? removeNewFiles()
      let isCleared = !Self.files(of: newStoreURL).contains {
        fileManager.fileExists(atPath: $0.path)
      }
      guard !isCleared, ContinuousClock.now < deadline else { return }
      Self.pauseBetweenChecks()
    }
  }

  /// A failure here doesn't fail the migration, because the new store is already good. The next
  /// launch tries again.
  ///
  /// The store file moves last, so a run that stops partway still leaves it to match on the next
  /// launch, and never leaves a stray `-wal` that a store created later would replay. That's why a
  /// missing `-wal` still counts as unchanged: a real write that removed it changes the store file.
  ///
  /// A changed store isn't even opened to check for connections, since closing it could alter it.
  /// It's compared again afterwards, in case a connection wrote to it as it closed.
  private func backUpOldStoreIfUnchanged(
    _ migratedStore: MigratedStore,
    closeDeadline: ContinuousClock.Instant
  ) {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: oldStoreURL.path) else { return }
    guard
      isUnchanged(migratedStore),
      waitUntilClosed(oldStoreURL, closeDeadline: closeDeadline),
      isUnchanged(migratedStore)
    else {
      RunwayModelContainer.logger.notice(
        "The store at the old location changed or is still open; leaving it in place"
      )
      return
    }
    let backupURL = oldStoreURL.deletingLastPathComponent()
      .appending(path: migratedStore.backupName)
    let moves = Array(zip(Self.files(of: oldStoreURL), Self.files(of: backupURL))).reversed()
    for (source, destination) in moves where fileManager.fileExists(atPath: source.path) {
      do {
        // An earlier run moved this sidecar, and checking for connections since recreated it.
        if fileManager.fileExists(atPath: destination.path), isDisposableSidecar(source) {
          try fileManager.removeItem(at: source)
        } else {
          try fileManager.moveItem(at: source, to: destination)
        }
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
