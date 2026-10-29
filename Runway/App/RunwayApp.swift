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
      if let scenario = options.screenshotScenario {
        try scenario.seed(into: container.mainContext, now: .now, calendar: .current)
      }
      modelContainer = container
    } catch {
      fatalError("Failed to create the Runway model container: \(error)")
    }
  }

  var body: some Scene {
    WindowGroup {
      RootView(opensSetupOnLaunch: launchOptions.screenshotScenario != nil)
    }
    .modelContainer(modelContainer)
  }
}
