import Foundation
import SwiftData
import Testing

@testable import Runway

/// First-launch routing, launch arguments, and the screenshot scenarios' seed data.
struct AppLaunchTests {
  let calendar = Calendar.gregorian("America/Chicago")

  @Test("Without a budget the app opens setup; with one it opens the main screen")
  func route() {
    #expect(AppRoute(hasBudget: false) == .setup)
    #expect(AppRoute(hasBudget: true) == .main)
  }

  @Test("No launch arguments means the on-disk store and no scenario")
  func defaultLaunchOptions() {
    let options = LaunchOptions(arguments: ["Runway"])
    #expect(!options.usesInMemoryStore)
    #expect(options.screenshotScenario == nil)
  }

  @Test("Screenshot arguments select the in-memory store and a scenario")
  func screenshotLaunchOptions() {
    for scenario in ScreenshotScenario.allCases {
      let options = LaunchOptions(arguments: [
        "Runway",
        "-RunwayInMemoryStore",
        "-RunwayScreenshotScenario",
        scenario.rawValue,
      ])
      #expect(options.usesInMemoryStore)
      #expect(options.screenshotScenario == scenario)
    }
  }

  @Test("A scenario is ignored without the in-memory store, or when unknown or missing")
  func ignoredScenarios() {
    let onDisk = LaunchOptions(arguments: ["Runway", "-RunwayScreenshotScenario", "setup-filled"])
    #expect(!onDisk.usesInMemoryStore)
    #expect(onDisk.screenshotScenario == nil)

    let unknown = LaunchOptions(arguments: [
      "Runway",
      "-RunwayInMemoryStore",
      "-RunwayScreenshotScenario",
      "nope",
    ])
    #expect(unknown.usesInMemoryStore)
    #expect(unknown.screenshotScenario == nil)

    let missing = LaunchOptions(arguments: [
      "Runway",
      "-RunwayInMemoryStore",
      "-RunwayScreenshotScenario",
    ])
    #expect(missing.screenshotScenario == nil)
  }

  @Test("Screenshot scrolling accepts spendable only with the in-memory store")
  func screenshotScrollOptions() {
    let arguments = ["Runway", "-RunwayInMemoryStore", "-RunwayScreenshotScrollTo"]
    #expect(LaunchOptions(arguments: arguments + ["spendable"]).screenshotScrollTo == "spendable")
    #expect(LaunchOptions(arguments: arguments + ["unknown"]).screenshotScrollTo == nil)
    #expect(LaunchOptions(arguments: arguments).screenshotScrollTo == nil)
    #expect(LaunchOptions(arguments: ["Runway"]).screenshotScrollTo == nil)
    let onDisk = LaunchOptions(arguments: ["Runway", "-RunwayScreenshotScrollTo", "spendable"])
    #expect(onDisk.screenshotScrollTo == nil)
  }

  @Test("Scenario names match the CI workflow")
  func scenarioNames() {
    #expect(
      ScreenshotScenario.allCases.map(\.rawValue) == [
        "setup-empty",
        "setup-filled",
        "setup-warning",
      ]
    )
  }

  @Test("Scenarios seed no budget, a healthy one, and one with nothing available")
  func scenarioSeeds() throws {
    let now = calendar.date(2026, 6, 10, 12)
    var available: [ScreenshotScenario: Int] = [:]
    for scenario in ScreenshotScenario.allCases {
      let container = try RunwayModelContainer.make(inMemory: true)
      let context = ModelContext(container)
      let budget = try scenario.seed(into: context, now: now, calendar: calendar)
      #expect(try context.fetchCount(FetchDescriptor<Budget>()) == (budget == nil ? 0 : 1))
      if let budget {
        #expect(budget.periodStart == calendar.date(2026, 6, 7))
        let draft = BudgetDraft(budget: budget, locale: Money.fixedLocale)
        #expect(draft.canSave)
        available[scenario] = draft.availableCents
      }
    }
    #expect(available == [.setupFilled: 99_500, .setupWarning: -25_000])
  }
}
