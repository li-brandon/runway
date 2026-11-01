import Foundation
import SQLite3
import SwiftData
import Testing

@testable import Runway

/// Moving the store into the App Group container, on real on-disk stores in a temp directory.
struct StoreMigrationTests {
  private struct VerifyFailure: Error {}
  private struct SQLiteFailure: Error {
    let code: Int32
  }

  /// The old and new store locations, with their own defaults so no test touches the app's.
  private struct Stores {
    let directory: URL
    let old: URL
    let new: URL
    let defaults: UserDefaults
  }

  private let date = Date(timeIntervalSinceReferenceDate: 800_000_000)

  private func withDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "RunwayTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
  }

  private func withStores(_ body: (Stores) throws -> Void) throws {
    let suiteName = "RunwayTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    try withDirectory { directory in
      try body(
        Stores(
          directory: directory,
          old: try oldURL(in: directory),
          new: newURL(in: directory),
          defaults: defaults
        )
      )
    }
  }

  private func migration(_ stores: Stores) -> StoreMigration {
    StoreMigration(
      oldStoreURL: stores.old,
      newStoreURL: stores.new,
      defaults: stores.defaults,
      now: date
    )
  }

  private func oldURL(in directory: URL) throws -> URL {
    let old = directory.appending(path: "old")
    try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
    return old.appending(path: "default.store")
  }

  private func newURL(in directory: URL) -> URL {
    RunwayModelContainer.storeURL(inGroupContainer: directory.appending(path: "group"))
  }

  /// Creates a store at `url` holding a budget, an expense, and one more for each of `extraNotes`.
  ///
  /// It's built at a scratch path and only its checkpointed file is copied to `url`, because a
  /// released container can stay open for a while. Closing it late would checkpoint into the store
  /// file, changing its size and date, and unlink the `-wal` at its path even if a different store
  /// lives there by then. No connection ever has `url` open, so nothing can change it afterward.
  private func seedStore(at url: URL, extraNotes: [String] = []) throws {
    try withDirectory { directory in
      let scratch = directory.appending(path: url.lastPathComponent)
      try autoreleasepool {
        let context = ModelContext(try RunwayModelContainer.make(url: scratch))
        context.insert(Budget(periodStart: date, spendablePerPeriodCents: 110_000))
        let service = CategoryService(context: context)
        try service.createExpense(amountCents: 1_250, note: "Lunch", date: date, now: date)
        for note in extraNotes {
          try service.createExpense(amountCents: 500, note: note, date: date, now: date)
        }
        try context.save()
      }
      try checkpoint(scratch)
      try FileManager.default.copyItem(at: scratch, to: url)
    }
  }

  /// Moves everything in the `-wal` into the store file, even if a released container still has the
  /// store open. That container has nothing left to write when it does close.
  private func checkpoint(_ url: URL) throws {
    var database: OpaquePointer?
    defer { sqlite3_close(database) }
    let opened = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil)
    guard opened == SQLITE_OK else { throw SQLiteFailure(code: opened) }
    sqlite3_busy_timeout(database, 5_000)
    let result = sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
    guard result == SQLITE_OK else { throw SQLiteFailure(code: result) }
  }

  /// Read-only, so a migration that runs after this can't see a write from it.
  private func expectSeededData(at url: URL) throws {
    try autoreleasepool {
      let context = ModelContext(try RunwayModelContainer.makeReadOnly(url: url))
      let budget = try #require(try context.fetch(FetchDescriptor<Budget>()).first)
      #expect(budget.spendablePerPeriodCents == 110_000)
      let expense = try #require(try context.fetch(FetchDescriptor<Expense>()).first)
      #expect(expense.amountCents == 1_250)
      #expect(expense.note == "Lunch")
    }
  }

  private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
  }

  /// The URL of a file next to `url`, like its `-wal` sidecar.
  private func sibling(of url: URL, named name: String) -> URL {
    url.deletingLastPathComponent().appending(path: name)
  }

  private func backupURL(of stores: Stores) -> URL {
    StoreMigration.backupURL(for: stores.old, date: date)
  }

  /// Blocks the rename of the old store, so a migration finishes with it still in place.
  private func blockBackup(of stores: Stores) throws {
    try Data("blocker".utf8).write(to: backupURL(of: stores))
  }

  /// Leaves `url` open to a late close, so only use it on a store no test compares byte for byte.
  private func addExpense(at url: URL, note: String) throws {
    try autoreleasepool {
      let context = ModelContext(try RunwayModelContainer.make(url: url))
      try CategoryService(context: context).createExpense(
        amountCents: 500,
        note: note,
        date: date,
        now: date
      )
      try context.save()
    }
  }

  private func expenseCount(at url: URL) throws -> Int {
    try autoreleasepool {
      let context = ModelContext(try RunwayModelContainer.makeReadOnly(url: url))
      return try context.fetchCount(FetchDescriptor<Expense>())
    }
  }

  @Test("A store written at the old path reads back at the new path, and the old one is backed up")
  func migratesRealStore() throws {
    try withStores { stores in
      try seedStore(at: stores.old)

      #expect(try migration(stores).run() == .migrated)

      try expectSeededData(at: stores.new)
      #expect(!exists(stores.old))
      #expect(!exists(sibling(of: stores.old, named: "default.store-wal")))
      #expect(!exists(sibling(of: stores.old, named: "default.store-shm")))
      #expect(StoreMigration.isComplete(newStoreURL: stores.new))
      #expect(StoreMigration.isRecordedComplete(in: stores.defaults))
      try expectSeededData(at: backupURL(of: stores))
    }
  }

  @Test("The marker records the old store's counts, size, modification date, and backup name")
  func markerRecordsWhatWasMigrated() throws {
    try withStores { stores in
      try seedStore(at: stores.old)
      let counts = try RunwayModelContainer.readOnlyStoreCounts(at: stores.old)
      let attributes = try FileManager.default.attributesOfItem(atPath: stores.old.path)

      try migration(stores).run()

      let migrated = try #require(StoreMigration.marker(newStoreURL: stores.new)?.migratedStore)
      #expect(migrated.counts == counts)
      #expect(migrated.counts.values.reduce(0, +) >= 2)
      let size = try #require(attributes[.size] as? UInt64)
      let modified = try #require(attributes[.modificationDate] as? Date)
      #expect(migrated.store == StoreMigration.FileStamp(size: size, modified: modified))
      #expect(migrated.backupName == backupURL(of: stores).lastPathComponent)
    }
  }

  @Test("The store, its sidecars, and external storage are all copied, then moved to the backup")
  func copiesEveryFile() throws {
    try withStores { stores in
      let fileManager = FileManager.default
      let support = sibling(of: stores.old, named: ".default_SUPPORT/_EXTERNAL_DATA")
      try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
      let relativePaths = [
        "default.store",
        "default.store-wal",
        "default.store-shm",
        ".default_SUPPORT/_EXTERNAL_DATA/asset",
      ]
      for path in relativePaths {
        try Data(path.utf8).write(to: sibling(of: stores.old, named: path))
      }

      let run = StoreMigration(
        oldStoreURL: stores.old,
        newStoreURL: stores.new,
        defaults: stores.defaults,
        now: date,
        countOldStore: { _ in [:] },
        countNewStore: { _ in [:] }
      )
      #expect(try run.run() == .migrated)

      let backup = backupURL(of: stores)
      let backupStem = backup.deletingPathExtension().lastPathComponent
      let backupPaths = [
        backup.lastPathComponent,
        "\(backup.lastPathComponent)-wal",
        "\(backup.lastPathComponent)-shm",
        ".\(backupStem)_SUPPORT/_EXTERNAL_DATA/asset",
      ]
      for (path, backupPath) in zip(relativePaths, backupPaths) {
        #expect(try Data(contentsOf: sibling(of: stores.new, named: path)) == Data(path.utf8))
        #expect(!exists(sibling(of: stores.old, named: path)))
        #expect(
          try Data(contentsOf: sibling(of: stores.old, named: backupPath)) == Data(path.utf8)
        )
      }
      #expect(!exists(sibling(of: stores.old, named: ".default_SUPPORT")))
    }
  }

  @Test("A second run does nothing, and keeps what was saved after the first")
  func secondRunIsNoOp() throws {
    try withStores { stores in
      try seedStore(at: stores.old)
      try migration(stores).run()
      try addExpense(at: stores.new, note: "After the move")

      let second = StoreMigration(
        oldStoreURL: stores.old,
        newStoreURL: stores.new,
        defaults: stores.defaults,
        countOldStore: { _ in
          Issue.record("A second run shouldn't open the old store")
          return [:]
        },
        countNewStore: { _ in
          Issue.record("A second run shouldn't open the new store")
          return [:]
        }
      )
      #expect(try second.run() == .alreadyMigrated)

      #expect(try expenseCount(at: stores.new) == 2)
    }
  }

  @Test("A copy missing rows leaves the old store intact and no marker, and the retry succeeds")
  func mismatchedCountsKeepOldStore() throws {
    try withStores { stores in
      try seedStore(at: stores.old)
      let oldBytes = try Data(contentsOf: stores.old)
      let lossy = StoreMigration(
        oldStoreURL: stores.old,
        newStoreURL: stores.new,
        defaults: stores.defaults,
        now: date,
        countNewStore: { url in
          // A copy that opens fine but lost a row.
          let context = ModelContext(try RunwayModelContainer.make(url: url))
          let expense = try #require(try context.fetch(FetchDescriptor<Expense>()).first)
          context.delete(expense)
          try context.save()
          return try RunwayModelContainer.storeCounts(at: url)
        }
      )

      #expect(throws: RunwayStoreError.self) { try lossy.run() }

      #expect(!exists(stores.new))
      #expect(!exists(sibling(of: stores.new, named: "default.store-wal")))
      #expect(!StoreMigration.isComplete(newStoreURL: stores.new))
      #expect(!StoreMigration.isRecordedComplete(in: stores.defaults))
      #expect(!exists(backupURL(of: stores)))
      #expect(try Data(contentsOf: stores.old) == oldBytes)
      try expectSeededData(at: stores.old)

      #expect(try migration(stores).run() == .migrated)
      try expectSeededData(at: stores.new)
    }
  }

  @Test("A copy that won't open leaves the old store intact and no new store, and retrying works")
  func failedVerifyKeepsOldStore() throws {
    try withStores { stores in
      try seedStore(at: stores.old)
      let failing = StoreMigration(
        oldStoreURL: stores.old,
        newStoreURL: stores.new,
        defaults: stores.defaults,
        countNewStore: { _ in throw VerifyFailure() }
      )

      #expect(throws: VerifyFailure.self) { try failing.run() }

      #expect(!exists(stores.new))
      #expect(!StoreMigration.isComplete(newStoreURL: stores.new))
      #expect(!StoreMigration.isRecordedComplete(in: stores.defaults))
      #expect(exists(stores.old))
      #expect(try migration(stores).run() == .migrated)
      try expectSeededData(at: stores.new)
    }
  }

  @Test("An old store that can't be counted isn't copied")
  func unreadableOldStoreIsNotCopied() throws {
    try withStores { stores in
      try seedStore(at: stores.old)
      let failing = StoreMigration(
        oldStoreURL: stores.old,
        newStoreURL: stores.new,
        defaults: stores.defaults,
        countOldStore: { _ in throw VerifyFailure() }
      )

      #expect(throws: VerifyFailure.self) { try failing.run() }

      #expect(!exists(stores.new))
      #expect(!StoreMigration.isComplete(newStoreURL: stores.new))
      try expectSeededData(at: stores.old)
    }
  }

  @Test("A copy interrupted before the marker is discarded and redone from the old store")
  func interruptedCopyStartsOver() throws {
    try withStores { stores in
      try seedStore(at: stores.old)
      try FileManager.default.createDirectory(
        at: stores.new.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data("partial".utf8).write(to: stores.new)
      try Data("partial".utf8).write(to: sibling(of: stores.new, named: "default.store-wal"))

      #expect(try migration(stores).run() == .migrated)

      try expectSeededData(at: stores.new)
    }
  }

  @Test("An unchanged old store that a finished migration couldn't back up is retried next run")
  func retriesBackingUpOldStore() throws {
    try withStores { stores in
      try seedStore(at: stores.old)
      try blockBackup(of: stores)

      #expect(try migration(stores).run() == .migrated)
      #expect(exists(stores.old))
      try FileManager.default.removeItem(at: backupURL(of: stores))

      #expect(try migration(stores).run() == .alreadyMigrated)

      #expect(!exists(stores.old))
      try expectSeededData(at: backupURL(of: stores))
      try expectSeededData(at: stores.new)
    }
  }

  @Test("An old store with a different size since the migration isn't touched")
  func changedSizeKeepsOldStore() throws {
    try expectOldStoreKept { stores in
      let handle = try FileHandle(forWritingTo: stores.old)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: Data("more".utf8))
    }
  }

  @Test("An old store with a different modification date since the migration isn't touched")
  func changedDateKeepsOldStore() throws {
    try expectOldStoreKept { stores in
      try FileManager.default.setAttributes(
        [.modificationDate: date],
        ofItemAtPath: stores.old.path
      )
    }
  }

  @Test("An old store with new writes only in its -wal since the migration isn't touched")
  func changedWALKeepsOldStore() throws {
    try expectOldStoreKept { stores in
      try Data("new writes".utf8).write(to: sibling(of: stores.old, named: "default.store-wal"))
    }
  }

  /// A migration that couldn't back up the old store, then `change`, then a run free to back it up.
  private func expectOldStoreKept(after change: (Stores) throws -> Void) throws {
    try withStores { stores in
      try seedStore(at: stores.old)
      try blockBackup(of: stores)
      try migration(stores).run()
      try FileManager.default.removeItem(at: backupURL(of: stores))
      try change(stores)
      let oldBytes = try Data(contentsOf: stores.old)

      #expect(try migration(stores).run() == .alreadyMigrated)

      #expect(try Data(contentsOf: stores.old) == oldBytes)
      #expect(!exists(backupURL(of: stores)))
      try expectSeededData(at: stores.new)
    }
  }

  @Test("After a downgrade and upgrade, the recreated old store and the backup are left alone")
  func downgradeThenUpgradeTouchesNothing() throws {
    try withStores { stores in
      try seedStore(at: stores.old)
      try migration(stores).run()
      try addExpense(at: stores.new, note: "After the move")
      let backup = backupURL(of: stores)
      let backupBytes = try Data(contentsOf: backup)

      // The older build writes to the old location again.
      try seedStore(at: stores.old, extraNotes: ["While downgraded", "While downgraded, again"])
      let oldBytes = try Data(contentsOf: stores.old)

      let resolved = try RunwayModelContainer.resolveStoreURL(
        shared: stores.new,
        legacy: stores.old,
        defaults: stores.defaults
      )

      #expect(resolved == stores.new)
      #expect(try Data(contentsOf: stores.old) == oldBytes)
      #expect(try Data(contentsOf: backup) == backupBytes)
      #expect(try expenseCount(at: stores.new) == 2)
      #expect(try expenseCount(at: stores.old) == 3)
    }
  }

  @Test("A store appearing at the old location after a fresh install isn't touched")
  func freshInstallLeavesLaterOldStoreAlone() throws {
    try withStores { stores in
      #expect(try migration(stores).run() == .nothingToMigrate)
      try seedStore(at: stores.old)

      #expect(try migration(stores).run() == .alreadyMigrated)

      try expectSeededData(at: stores.old)
      #expect(!exists(stores.new))
    }
  }

  @Test("A marker that can't be read still means migrated, and the old store is left alone")
  func unreadableMarkerLeavesOldStoreAlone() throws {
    try withStores { stores in
      try seedStore(at: stores.old)
      try FileManager.default.createDirectory(
        at: stores.new.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data().write(to: sibling(of: stores.new, named: "default.store.migrated"))

      #expect(try migration(stores).run() == .alreadyMigrated)

      try expectSeededData(at: stores.old)
      #expect(!exists(stores.new))
      #expect(StoreMigration.isRecordedComplete(in: stores.defaults))
    }
  }

  @Test("A fresh install has nothing to migrate, and a widget can tell the location is ready")
  func freshInstall() throws {
    try withStores { stores in
      let run = StoreMigration(
        oldStoreURL: stores.old,
        newStoreURL: stores.new,
        defaults: stores.defaults,
        countOldStore: { _ in
          Issue.record("There's no store to open")
          return [:]
        },
        countNewStore: { _ in
          Issue.record("There's no store to open")
          return [:]
        }
      )

      let result = try run.run()
      #expect(result == .nothingToMigrate)

      #expect(!exists(stores.new))
      #expect(StoreMigration.isComplete(newStoreURL: stores.new))
      #expect(StoreMigration.isRecordedComplete(in: stores.defaults))
    }
  }

  @Test("Without an App Group before any migration, the store stays at the default location")
  func fallsBackWithoutAppGroup() throws {
    try withStores { stores in
      try seedStore(at: stores.old)

      let resolved = try RunwayModelContainer.resolveStoreURL(
        shared: nil,
        legacy: stores.old,
        defaults: stores.defaults
      )

      #expect(resolved == stores.old)
      try expectSeededData(at: stores.old)
    }
  }

  @Test("Data written during a fallback is migrated once the App Group returns")
  func fallbackThenReturnMigrates() throws {
    try withStores { stores in
      let fallback = try RunwayModelContainer.resolveStoreURL(
        shared: nil,
        legacy: stores.old,
        defaults: stores.defaults
      )
      try seedStore(at: fallback)

      let resolved = try RunwayModelContainer.resolveStoreURL(
        shared: stores.new,
        legacy: stores.old,
        defaults: stores.defaults
      )

      #expect(resolved == stores.new)
      try expectSeededData(at: stores.new)
      #expect(!exists(stores.old))
      #expect(StoreMigration.isRecordedComplete(in: stores.defaults))
    }
  }

  @Test("Once migrated, losing the App Group throws instead of opening the old location")
  func appGroupLostAfterMigrationThrows() throws {
    try withStores { stores in
      try seedStore(at: stores.old)
      try migration(stores).run()

      #expect(throws: RunwayStoreError.sharedStoreUnavailable) {
        _ = try RunwayModelContainer.resolveStoreURL(
          shared: nil,
          legacy: stores.old,
          defaults: stores.defaults
        )
      }

      #expect(!exists(stores.old))
    }
  }

  @Test("After a fresh install, losing the App Group throws too, since the data lives there")
  func appGroupLostAfterFreshInstallThrows() throws {
    try withStores { stores in
      try migration(stores).run()

      #expect(throws: RunwayStoreError.sharedStoreUnavailable) {
        _ = try RunwayModelContainer.resolveStoreURL(
          shared: nil,
          legacy: stores.old,
          defaults: stores.defaults
        )
      }

      #expect(!exists(stores.old))
    }
  }

  @Test("A recorded migration whose marker is gone throws rather than migrating again")
  func recordedWithoutMarkerThrows() throws {
    try withStores { stores in
      try seedStore(at: stores.old)
      try migration(stores).run()
      let marker = sibling(of: stores.new, named: "default.store.migrated")
      try FileManager.default.removeItem(at: marker)
      try seedStore(at: stores.old)
      let oldBytes = try Data(contentsOf: stores.old)

      #expect(throws: RunwayStoreError.sharedStoreUnavailable) {
        _ = try RunwayModelContainer.resolveStoreURL(
          shared: stores.new,
          legacy: stores.old,
          defaults: stores.defaults
        )
      }

      #expect(try Data(contentsOf: stores.old) == oldBytes)
      try expectSeededData(at: stores.new)
    }
  }

  @Test("A marker without a record restores the record, so a later outage still fails visibly")
  func markerRestoresRecord() throws {
    try withStores { stores in
      try seedStore(at: stores.old)
      try migration(stores).run()
      stores.defaults.removeObject(forKey: "StoreMigration.completed")

      #expect(try migration(stores).run() == .alreadyMigrated)

      #expect(StoreMigration.isRecordedComplete(in: stores.defaults))
    }
  }

  @Test("If the App Group location can't be written, the store stays at the default location")
  func fallsBackWhenMigrationFails() throws {
    try withStores { stores in
      try seedStore(at: stores.old)
      // A file where the group directory should be makes creating the directory fail.
      let blocker = stores.directory.appending(path: "group")
      try Data().write(to: blocker)

      let resolved = try RunwayModelContainer.resolveStoreURL(
        shared: stores.new,
        legacy: stores.old,
        defaults: stores.defaults
      )

      #expect(resolved == stores.old)
      try expectSeededData(at: stores.old)
      #expect(!StoreMigration.isRecordedComplete(in: stores.defaults))
    }
  }

  @Test("The legacy URL is where SwiftData's default configuration kept the store")
  func legacyURLMatchesDefaultConfiguration() {
    let configuration = ModelConfiguration(
      schema: Schema(versionedSchema: RunwaySchemaV1.self),
      groupContainer: .none,
      cloudKitDatabase: .none
    )
    let legacyPath = RunwayModelContainer.legacyStoreURL.resolvingSymlinksInPath().path
    #expect(configuration.url.resolvingSymlinksInPath().path == legacyPath)
  }

  @Test("A read-only container reads the store and doesn't allow saves")
  func readOnlyContainerReads() throws {
    try withDirectory { directory in
      let url = directory.appending(path: "default.store")
      try seedStore(at: url)

      let container = try RunwayModelContainer.makeReadOnly(url: url)

      #expect(container.configurations.allSatisfy { !$0.allowsSave })
      let context = ModelContext(container)
      #expect(try context.fetchCount(FetchDescriptor<Budget>()) == 1)
      #expect(try context.fetchCount(FetchDescriptor<Expense>()) == 1)
    }
  }

  @Test("A read-only container throws rather than creating a missing store")
  func readOnlyContainerNeedsStore() throws {
    try withDirectory { directory in
      let url = directory.appending(path: "default.store")

      #expect(throws: RunwayStoreError.storeNotReady) {
        _ = try RunwayModelContainer.makeReadOnly(url: url)
      }

      #expect(!exists(url))
    }
  }

  @Test("Export, reset, and import work on a migrated store and survive a relaunch")
  func privacyActionsWorkAfterMigration() throws {
    try withStores { stores in
      let new = stores.new
      try seedStore(at: stores.old)
      try migration(stores).run()

      let exported: RunwaySnapshot
      do {
        let context = ModelContext(try RunwayModelContainer.make(url: new))
        exported = try DataExport.snapshot(of: context, now: date)
        try DataReset.reset(in: context, legacyStoreURL: stores.old)
      }
      do {
        let context = ModelContext(try RunwayModelContainer.make(url: new))
        #expect(try context.fetchCount(FetchDescriptor<Expense>()) == 0)
        let data = try DataExport.jsonData(from: exported)
        try DataImport.apply(try DataImport.validate(data), to: context)
      }

      let context = ModelContext(try RunwayModelContainer.make(url: new))
      #expect(try DataExport.snapshot(of: context, now: date) == exported)
    }
  }

  /// Gives the migration's backup the sidecars and support directory a real one can have.
  private func addBackupSidecars(_ stores: Stores) throws -> [URL] {
    let backup = backupURL(of: stores)
    let stem = backup.deletingPathExtension().lastPathComponent
    let support = sibling(of: stores.old, named: ".\(stem)_SUPPORT/_EXTERNAL_DATA")
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    try Data("asset".utf8).write(to: support.appending(path: "asset"))
    let sidecars = ["-wal", "-shm"].map {
      sibling(of: backup, named: backup.lastPathComponent + $0)
    }
    for sidecar in sidecars {
      try Data("sidecar".utf8).write(to: sidecar)
    }
    return [backup, sibling(of: stores.old, named: ".\(stem)_SUPPORT")] + sidecars
  }

  private func namesAtOldLocation(_ stores: Stores) throws -> Set<String> {
    let names = try FileManager.default.contentsOfDirectory(
      atPath: stores.old.deletingLastPathComponent().path
    )
    return Set(names)
  }

  @Test("Reset after a migration erases backups and a changed old store, and the live store opens")
  func resetErasesLeftovers() throws {
    try withStores { stores in
      try seedStore(at: stores.old)
      try migration(stores).run()
      _ = try addBackupSidecars(stores)
      // A downgrade recreated the old store, with its external storage.
      try seedStore(at: stores.old)
      let oldSupport = sibling(of: stores.old, named: ".default_SUPPORT")
      try FileManager.default.createDirectory(at: oldSupport, withIntermediateDirectories: true)
      try Data("asset".utf8).write(to: oldSupport.appending(path: "asset"))
      let unrelated = sibling(of: stores.old, named: "unrelated.txt")
      try Data("keep".utf8).write(to: unrelated)

      do {
        let context = ModelContext(try RunwayModelContainer.make(url: stores.new))
        try DataReset.reset(in: context, legacyStoreURL: stores.old)
      }

      let remaining = try namesAtOldLocation(stores)
      #expect(remaining == ["unrelated.txt"])
      #expect(exists(stores.new))
      #expect(StoreMigration.isComplete(newStoreURL: stores.new))
      let context = ModelContext(try RunwayModelContainer.make(url: stores.new))
      let expenses = try context.fetchCount(FetchDescriptor<Expense>())
      let categories = try CategoryService(context: context).categories()
      #expect(expenses == 0)
      #expect(categories.map(\.name) == CategoryService.defaultNames)

      let resolved = try RunwayModelContainer.resolveStoreURL(
        shared: stores.new,
        legacy: stores.old,
        defaults: stores.defaults
      )
      #expect(resolved == stores.new)
    }
  }

  @Test("A failed reset save deletes neither the backup nor the old store")
  func failedResetKeepsLeftovers() throws {
    try withStores { stores in
      try seedStore(at: stores.old)
      try migration(stores).run()
      let backupFiles = try addBackupSidecars(stores)
      try seedStore(at: stores.old)

      let context = ModelContext(try RunwayModelContainer.make(url: stores.new))
      #expect(throws: VerifyFailure.self) {
        try DataReset.reset(in: context, legacyStoreURL: stores.old) { _ in
          throw VerifyFailure()
        }
      }

      for file in backupFiles + [stores.old] {
        #expect(exists(file))
      }
      let expenses = try context.fetchCount(FetchDescriptor<Expense>())
      #expect(expenses == 1)
    }
  }

  @Test("When the app is running from the old location, reset keeps that store and its sidecars")
  func resetKeepsLiveStoreAtOldLocation() throws {
    try withStores { stores in
      try seedStore(at: stores.old)
      let backup = backupURL(of: stores)
      try Data("backup".utf8).write(to: backup)

      do {
        let context = ModelContext(try RunwayModelContainer.make(url: stores.old))
        try DataReset.reset(in: context, legacyStoreURL: stores.old)
      }

      #expect(!exists(backup))
      #expect(exists(stores.old))
      let context = ModelContext(try RunwayModelContainer.make(url: stores.old))
      let expenses = try context.fetchCount(FetchDescriptor<Expense>())
      let categories = try CategoryService(context: context).categories()
      #expect(expenses == 0)
      #expect(categories.map(\.name) == CategoryService.defaultNames)
    }
  }

  @Test("Resetting an in-memory store leaves files on disk alone")
  func inMemoryResetLeavesDiskAlone() throws {
    try withStores { stores in
      try seedStore(at: stores.old)
      try migration(stores).run()
      let backupFiles = try addBackupSidecars(stores)
      try seedStore(at: stores.old)

      let context = ModelContext(try RunwayModelContainer.make(inMemory: true))
      try DataReset.reset(in: context, legacyStoreURL: stores.old)

      for file in backupFiles + [stores.old] {
        #expect(exists(file))
      }
    }
  }

  @Test("Files that can't be deleted are reported, the reset still holds, and a retry finishes")
  func undeletableLeftoversThrow() throws {
    try withStores { stores in
      try seedStore(at: stores.old)
      try migration(stores).run()
      let oldDirectory = stores.old.deletingLastPathComponent()
      let fileManager = FileManager.default
      try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: oldDirectory.path)
      // Restored here as well so the temp directory can be cleaned up if an expectation throws.
      defer {
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: oldDirectory.path)
      }

      let context = ModelContext(try RunwayModelContainer.make(url: stores.new))
      #expect(throws: DataResetError.leftoverFilesRemain) {
        try DataReset.reset(in: context, legacyStoreURL: stores.old)
      }

      let expenses = try context.fetchCount(FetchDescriptor<Expense>())
      #expect(expenses == 0)
      #expect(exists(backupURL(of: stores)))

      try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: oldDirectory.path)
      try DataReset.reset(in: context, legacyStoreURL: stores.old)
      let remaining = try namesAtOldLocation(stores)
      #expect(remaining.isEmpty)
    }
  }
}
