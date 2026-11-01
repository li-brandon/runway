import Foundation
import SwiftData
import os

enum RunwayStoreError: Error, Equatable {
  /// The shared store doesn't exist yet, or hasn't finished moving there.
  case storeNotReady
  /// The store already moved to the App Group container, but that store can't be reached now.
  /// Opening the old location instead would show the user an empty or out-of-date app.
  case sharedStoreUnavailable
  /// The copy opened but doesn't hold the same number of rows of every model as the original.
  case migrationCountMismatch(expected: [String: Int], found: [String: Int])
}

/// Builds the app's SwiftData container. Data stays on device; CloudKit sync is off.
///
/// Every on-disk store is opened by explicit URL. Once the app has an App Group entitlement, a
/// `ModelConfiguration` with no URL silently moves to the group container, which would hide the
/// existing store instead of migrating it.
enum RunwayModelContainer {
  static let appGroupIdentifier = "group.com.librandon.runway.shared"
  static let logger = Logger(subsystem: "com.librandon.runway", category: "Persistence")

  private static let storeFileName = "default.store"

  /// Where SwiftData kept the store before the App Group, and the fallback without one.
  static var legacyStoreURL: URL {
    URL.applicationSupportDirectory.appending(path: storeFileName)
  }

  /// The store in the App Group container, or nil when the build has no App Group, as in unsigned
  /// CI builds.
  static var sharedStoreURL: URL? {
    FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
      .map(storeURL(inGroupContainer:))
  }

  static func storeURL(inGroupContainer containerURL: URL) -> URL {
    containerURL.appending(path: "Library/Application Support/\(storeFileName)")
  }

  /// The app's on-disk store, moved to the App Group container first if needed, or a fresh
  /// in-memory store (tests, screenshots). Only the app calls this; widgets use `makeReadOnly()`.
  static func make(inMemory: Bool) throws -> ModelContainer {
    guard inMemory else {
      let url = try resolveStoreURL(
        shared: sharedStoreURL,
        legacy: legacyStoreURL,
        defaults: .standard
      )
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      return try make(url: url)
    }
    let schema = Schema(versionedSchema: RunwaySchemaV1.self)
    // Give each in-memory container its own store so parallel tests never share data.
    let configuration = ModelConfiguration(
      "Runway-\(UUID().uuidString)",
      schema: schema,
      isStoredInMemoryOnly: true,
      groupContainer: .none,
      cloudKitDatabase: .none
    )
    return try make(schema: schema, configuration: configuration)
  }

  /// An on-disk store at `url`. Tests use it to simulate a relaunch by opening a second
  /// container on the same file.
  static func make(url: URL) throws -> ModelContainer {
    let schema = Schema(versionedSchema: RunwaySchemaV1.self)
    let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
    return try make(schema: schema, configuration: configuration)
  }

  /// A read-only container on the shared store, for widgets. There's no fallback location, because
  /// a widget can't see the app's own container. It throws until the app has finished moving the
  /// store, so a widget never opens a half-copied one.
  static func makeReadOnly() throws -> ModelContainer {
    guard let url = sharedStoreURL, StoreMigration.isComplete(newStoreURL: url) else {
      throw RunwayStoreError.storeNotReady
    }
    return try makeReadOnly(url: url)
  }

  /// A read-only container on the existing store at `url`. Throws rather than creating a store.
  static func makeReadOnly(url: URL) throws -> ModelContainer {
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw RunwayStoreError.storeNotReady
    }
    let schema = Schema(versionedSchema: RunwaySchemaV1.self)
    let configuration = ModelConfiguration(
      schema: schema,
      url: url,
      allowsSave: false,
      cloudKitDatabase: .none
    )
    return try make(schema: schema, configuration: configuration)
  }

  /// The location to open: `shared` once any existing store has moved there, otherwise `legacy`. A
  /// failed move leaves the store at `legacy`, and the next launch tries again. Throws
  /// `sharedStoreUnavailable` rather than fall back once a move has finished, because the user's
  /// data is no longer at `legacy`.
  static func resolveStoreURL(shared: URL?, legacy: URL, defaults: UserDefaults) throws -> URL {
    guard let shared else {
      guard !StoreMigration.isRecordedComplete(in: defaults) else {
        logger.error("App Group container unavailable after the store moved there")
        throw RunwayStoreError.sharedStoreUnavailable
      }
      logger.notice("App Group container unavailable; using the default store location")
      return legacy
    }
    do {
      try StoreMigration(oldStoreURL: legacy, newStoreURL: shared, defaults: defaults).run()
      return shared
    } catch RunwayStoreError.sharedStoreUnavailable {
      logger.error("The moved store is missing from the App Group container")
      throw RunwayStoreError.sharedStoreUnavailable
    } catch {
      let reason = String(describing: error)
      logger.error("Store migration failed; using the old location: \(reason, privacy: .public)")
      return legacy
    }
  }

  /// Per-model row counts of the store at `url`, migrating its schema if needed. Throws unless it
  /// opens and every model can be read. The container is released on return.
  static func storeCounts(at url: URL) throws -> [String: Int] {
    try counts(in: ModelContext(try make(url: url)))
  }

  /// Per-model row counts of the existing store at `url`, opened read-only. The container is
  /// released on return.
  static func readOnlyStoreCounts(at url: URL) throws -> [String: Int] {
    try counts(in: ModelContext(try makeReadOnly(url: url)))
  }

  private static func counts(in context: ModelContext) throws -> [String: Int] {
    var counts: [String: Int] = [:]
    for model in RunwaySchemaV1.models {
      counts[String(describing: model)] = try count(model, in: context)
    }
    return counts
  }

  private static func count<M: PersistentModel>(
    _ type: M.Type,
    in context: ModelContext
  ) throws -> Int {
    try context.fetchCount(FetchDescriptor<M>())
  }

  private static func make(
    schema: Schema,
    configuration: ModelConfiguration
  ) throws -> ModelContainer {
    try ModelContainer(
      for: schema,
      migrationPlan: RunwayMigrationPlan.self,
      configurations: [configuration]
    )
  }
}
