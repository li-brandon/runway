import Foundation
import SwiftData
import os

enum RunwayStoreError: Error, Equatable {
  /// The shared store doesn't exist yet, or hasn't finished moving there.
  case storeNotReady
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
      let url = resolveStoreURL(shared: sharedStoreURL, legacy: legacyStoreURL)
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
  /// failed move leaves the store at `legacy`, and the next launch tries again.
  static func resolveStoreURL(shared: URL?, legacy: URL) -> URL {
    guard let shared else {
      logger.notice("App Group container unavailable; using the default store location")
      return legacy
    }
    do {
      try StoreMigration(oldStoreURL: legacy, newStoreURL: shared).run()
      return shared
    } catch {
      let reason = String(describing: error)
      logger.error("Store migration failed; using the old location: \(reason, privacy: .public)")
      return legacy
    }
  }

  /// Throws unless the store at `url` opens, migrating its schema if needed, and every model can
  /// be read. The container is released on return.
  static func verifyStore(at url: URL) throws {
    let context = ModelContext(try make(url: url))
    for model in RunwaySchemaV1.models {
      try checkReadable(model, in: context)
    }
  }

  private static func checkReadable<M: PersistentModel>(
    _ type: M.Type,
    in context: ModelContext
  ) throws {
    _ = try context.fetchCount(FetchDescriptor<M>())
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
