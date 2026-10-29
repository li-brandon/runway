import Foundation
import SwiftData
import SwiftUI

@main
struct RunwayApp: App {
  private let modelContainer: ModelContainer
  private let launchOptions: LaunchOptions

  init() {
    let options = LaunchOptions(arguments: ProcessInfo.processInfo.arguments)
    launchOptions = options
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
      RootView(screenshotScenario: launchOptions.screenshotScenario)
    }
    .modelContainer(modelContainer)
  }
}
