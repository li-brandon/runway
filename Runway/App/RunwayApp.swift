import SwiftData
import SwiftUI

@main
struct RunwayApp: App {
  private let modelContainer: ModelContainer

  init() {
    do {
      modelContainer = try RunwayModelContainer.make(inMemory: false)
    } catch {
      fatalError("Failed to create the Runway model container: \(error)")
    }
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
    }
    .modelContainer(modelContainer)
  }
}
