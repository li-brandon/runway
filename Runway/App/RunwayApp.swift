import Combine
import Foundation
import SwiftData
import SwiftUI
import WidgetKit

@main
struct RunwayApp: App {
  private let modelContainer: ModelContainer
  private let launchOptions: LaunchOptions
  @State private var appLock: AppLockController
  @Environment(\.scenePhase) private var scenePhase

  init() {
    let options = LaunchOptions(arguments: ProcessInfo.processInfo.arguments)
    launchOptions = options
    _appLock = State(initialValue: AppLockController.make(for: options))
    do {
      let container = try RunwayModelContainer.make(inMemory: options.usesInMemoryStore)
      try CategoryService(context: container.mainContext).seed()
      try container.mainContext.save()
      if let scenario = options.screenshotScenario {
        try scenario.seed(
          into: container.mainContext,
          now: scenario.todayDate ?? .now,
          calendar: .current
        )
      }
      modelContainer = container
    } catch {
      fatalError("Failed to create the Runway model container: \(error)")
    }
  }

  var body: some Scene {
    WindowGroup {
      AppLockGate(lock: appLock) {
        RootView(screenshotScenario: launchOptions.screenshotScenario)
      }
      // Every save posts this, whichever screen or context made it.
      .onReceive(
        NotificationCenter.default.publisher(for: ModelContext.didSave)
          .receive(on: RunLoop.main)
      ) { _ in
        reloadWidgets()
      }
      // Launching can finish moving the store, which a waiting widget needs to hear about.
      .onChange(of: scenePhase, initial: true) { _, phase in
        guard phase != .inactive else { return }
        reloadWidgets()
      }
    }
    .modelContainer(modelContainer)
  }

  /// In-memory launches hold sample data that widgets never see.
  private func reloadWidgets() {
    guard !launchOptions.usesInMemoryStore else { return }
    WidgetCenter.shared.reloadAllTimelines()
  }
}
