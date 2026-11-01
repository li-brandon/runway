import Foundation
import SwiftData
import Testing

@testable import Runway

/// Moving the store into the App Group container, on real on-disk stores in a temp directory.
struct StoreMigrationTests {
  private struct VerifyFailure: Error {}

  private let date = Date(timeIntervalSinceReferenceDate: 800_000_000)

  private func withDirectory(_ body: (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "RunwayTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
  }

  private func oldURL(in directory: URL) throws -> URL {
    let old = directory.appending(path: "old")
    try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
    return old.appending(path: "default.store")
  }

  private func newURL(in directory: URL) -> URL {
    RunwayModelContainer.storeURL(inGroupContainer: directory.appending(path: "group"))
  }

  /// Saves a budget and an expense with their own container, which is released on return.
  private func seedStore(at url: URL) throws {
    let context = ModelContext(try RunwayModelContainer.make(url: url))
    context.insert(Budget(periodStart: date, spendablePerPeriodCents: 110_000))
    try CategoryService(context: context).createExpense(
      amountCents: 1_250,
      note: "Lunch",
      date: date,
      now: date
    )
    try context.save()
  }

  private func expectSeededData(at url: URL) throws {
    let context = ModelContext(try RunwayModelContainer.make(url: url))
    let budget = try #require(try context.fetch(FetchDescriptor<Budget>()).first)
    #expect(budget.spendablePerPeriodCents == 110_000)
    let expense = try #require(try context.fetch(FetchDescriptor<Expense>()).first)
    #expect(expense.amountCents == 1_250)
    #expect(expense.note == "Lunch")
  }

  private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
  }

  /// The URL of a file next to `url`, like its `-wal` sidecar.
  private func sibling(of url: URL, named name: String) -> URL {
    url.deletingLastPathComponent().appending(path: name)
  }

  @Test("A store written at the old path reads back at the new path, and the old files are gone")
  func migratesRealStore() throws {
    try withDirectory { directory in
      let old = try oldURL(in: directory)
      let new = newURL(in: directory)
      try seedStore(at: old)

      let outcome = try StoreMigration(oldStoreURL: old, newStoreURL: new).run()

      #expect(outcome == .migrated)
      try expectSeededData(at: new)
      #expect(!exists(old))
      #expect(!exists(sibling(of: old, named: "default.store-wal")))
      #expect(!exists(sibling(of: old, named: "default.store-shm")))
    }
  }

  @Test("The store, its sidecars, and external storage are all copied")
  func copiesEveryFile() throws {
    try withDirectory { directory in
      let old = try oldURL(in: directory)
      let new = newURL(in: directory)
      let fileManager = FileManager.default
      let support = sibling(of: old, named: ".default_SUPPORT/_EXTERNAL_DATA")
      try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
      let relativePaths = [
        "default.store",
        "default.store-wal",
        "default.store-shm",
        ".default_SUPPORT/_EXTERNAL_DATA/asset",
      ]
      for path in relativePaths {
        try Data(path.utf8).write(to: sibling(of: old, named: path))
      }

      let migration = StoreMigration(oldStoreURL: old, newStoreURL: new, verify: { _ in })
      #expect(try migration.run() == .migrated)

      for path in relativePaths {
        #expect(try Data(contentsOf: sibling(of: new, named: path)) == Data(path.utf8))
        #expect(!exists(sibling(of: old, named: path)))
      }
      #expect(!exists(sibling(of: old, named: ".default_SUPPORT")))
    }
  }

  @Test("A second run does nothing, and keeps what was saved after the first")
  func secondRunIsNoOp() throws {
    try withDirectory { directory in
      let old = try oldURL(in: directory)
      let new = newURL(in: directory)
      try seedStore(at: old)
      let migration = StoreMigration(oldStoreURL: old, newStoreURL: new)
      try migration.run()
      do {
        let context = ModelContext(try RunwayModelContainer.make(url: new))
        try CategoryService(context: context).createExpense(
          amountCents: 500,
          note: "After the move",
          date: date,
          now: date
        )
        try context.save()
      }

      let second = StoreMigration(
        oldStoreURL: old,
        newStoreURL: new,
        verify: { _ in Issue.record("A second run shouldn't open the store") }
      )
      #expect(try second.run() == .alreadyMigrated)

      let context = ModelContext(try RunwayModelContainer.make(url: new))
      #expect(try context.fetchCount(FetchDescriptor<Expense>()) == 2)
    }
  }

  @Test("A failed open leaves the old store intact and no new store, and the retry succeeds")
  func failedVerifyKeepsOldStore() throws {
    try withDirectory { directory in
      let old = try oldURL(in: directory)
      let new = newURL(in: directory)
      try seedStore(at: old)
      let failing = StoreMigration(
        oldStoreURL: old,
        newStoreURL: new,
        verify: { _ in throw VerifyFailure() }
      )

      #expect(throws: VerifyFailure.self) { try failing.run() }

      #expect(!exists(new))
      #expect(!StoreMigration.isComplete(newStoreURL: new))
      #expect(exists(old))
      #expect(try StoreMigration(oldStoreURL: old, newStoreURL: new).run() == .migrated)
      try expectSeededData(at: new)
    }
  }

  @Test("A copy interrupted before the marker is discarded and redone from the old store")
  func interruptedCopyStartsOver() throws {
    try withDirectory { directory in
      let old = try oldURL(in: directory)
      let new = newURL(in: directory)
      try seedStore(at: old)
      try FileManager.default.createDirectory(
        at: new.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data("partial".utf8).write(to: new)
      try Data("partial".utf8).write(to: sibling(of: new, named: "default.store-wal"))

      #expect(try StoreMigration(oldStoreURL: old, newStoreURL: new).run() == .migrated)

      try expectSeededData(at: new)
    }
  }

  @Test("Old files left behind by a finished migration are removed by the next run")
  func retriesRemovingOldFiles() throws {
    try withDirectory { directory in
      let old = try oldURL(in: directory)
      let new = newURL(in: directory)
      try seedStore(at: old)
      try StoreMigration(oldStoreURL: old, newStoreURL: new).run()
      try Data("stale".utf8).write(to: old)

      #expect(try StoreMigration(oldStoreURL: old, newStoreURL: new).run() == .alreadyMigrated)

      #expect(!exists(old))
      try expectSeededData(at: new)
    }
  }

  @Test("A fresh install has nothing to migrate, and a widget can tell the location is ready")
  func freshInstall() throws {
    try withDirectory { directory in
      let new = newURL(in: directory)
      let migration = StoreMigration(
        oldStoreURL: try oldURL(in: directory),
        newStoreURL: new,
        verify: { _ in Issue.record("There's no store to open") }
      )

      #expect(try migration.run() == .nothingToMigrate)

      #expect(!exists(new))
      #expect(StoreMigration.isComplete(newStoreURL: new))
    }
  }

  @Test("Without an App Group container, the store stays at the default location")
  func fallsBackWithoutAppGroup() throws {
    try withDirectory { directory in
      let old = try oldURL(in: directory)
      try seedStore(at: old)

      #expect(RunwayModelContainer.resolveStoreURL(shared: nil, legacy: old) == old)

      try expectSeededData(at: old)
    }
  }

  @Test("If the App Group location can't be written, the store stays at the default location")
  func fallsBackWhenMigrationFails() throws {
    try withDirectory { directory in
      let old = try oldURL(in: directory)
      try seedStore(at: old)
      // A file where the group directory should be makes creating the directory fail.
      let blocker = directory.appending(path: "group")
      try Data().write(to: blocker)

      let resolved = RunwayModelContainer.resolveStoreURL(
        shared: newURL(in: directory),
        legacy: old
      )

      #expect(resolved == old)
      try expectSeededData(at: old)
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
    try withDirectory { directory in
      let old = try oldURL(in: directory)
      let new = newURL(in: directory)
      try seedStore(at: old)
      try StoreMigration(oldStoreURL: old, newStoreURL: new).run()

      let exported: RunwaySnapshot
      do {
        let context = ModelContext(try RunwayModelContainer.make(url: new))
        exported = try DataExport.snapshot(of: context, now: date)
        try DataReset.reset(in: context)
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
}
