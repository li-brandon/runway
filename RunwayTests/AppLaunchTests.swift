import Foundation
import SwiftData
import Testing

@testable import Runway

/// First-launch routing, launch arguments, and the screenshot scenarios' seed data.
struct AppLaunchTests {
  let calendar = Calendar.gregorian("America/Chicago")

  @Test("Without a budget Today hosts setup; with one it opens the main screen")
  func route() {
    #expect(AppRoute(hasBudget: false) == .setup)
    #expect(AppRoute(hasBudget: true) == .main)
  }

  @Test("The empty-state action opens the setup sheet after it was dismissed")
  func emptyStateOpensSetup() {
    var state = TodayEmptyState()
    #expect(state.showsSetup)
    state.showsSetup = false
    state.openSetup()
    #expect(state.showsSetup)

    var screenshotState = TodayEmptyState(opensSetup: false)
    #expect(!screenshotState.showsSetup)
    screenshotState.openSetup()
    #expect(screenshotState.showsSetup)
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

  @Test("Quick-log note screenshots require an in-memory store")
  func quickLogNoteLaunchOptions() {
    let arguments = ["Runway", "-RunwayScreenshotScenario", "quick-log-note"]
    #expect(LaunchOptions(arguments: arguments).screenshotScenario == nil)
    let options = LaunchOptions(arguments: arguments + ["-RunwayInMemoryStore"])
    #expect(options.screenshotScenario == .quickLogNote)
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
    let categories = LaunchOptions(arguments: arguments + ["categories"])
    #expect(categories.screenshotScrollTo == "categories")
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
        "categories",
        "category-picker",
        "quick-log-empty",
        "quick-log-filled",
        "quick-log-note",
        "today-undo",
        "today-normal",
        "today-near",
        "today-over",
        "today-zero",
        "today-no-budget",
        "history-list",
        "history-period-summary",
        "history-edit",
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
        let start = scenario.isHistory ? calendar.date(2026, 5, 24) : calendar.date(2026, 6, 7)
        #expect(budget.periodStart == start)
        let draft = BudgetDraft(budget: budget, locale: Money.fixedLocale)
        #expect(draft.canSave)
        available[scenario] = draft.availableCents
      }
    }
    #expect(
      available == [
        .setupFilled: 99_500,
        .setupWarning: -25_000,
        .quickLogEmpty: 99_500,
        .quickLogFilled: 99_500,
        .quickLogNote: 99_500,
        .todayUndo: 99_500,
        .todayNormal: 110_000,
        .todayNear: 110_000,
        .todayOver: 110_000,
        .todayZero: 0,
        .historyList: 110_000,
        .historyPeriodSummary: 110_000,
        .historyEdit: 110_000,
      ]
    )
  }

  @Test("Category screenshot scenarios seed persisted categories and distinct recent usage")
  func categoryScenarioSeeds() throws {
    let now = calendar.date(2026, 6, 10, 12)
    for scenario in [ScreenshotScenario.categories, .categoryPicker] {
      let container = try RunwayModelContainer.make(inMemory: true)
      let context = ModelContext(container)
      try scenario.seed(into: context, now: now, calendar: calendar)
      let loaded = ModelContext(container)
      let categories = try CategoryService(context: loaded).categories()
      #expect(categories.map(\.name) == CategoryService.defaultNames)
      let expenses = try loaded.fetch(
        FetchDescriptor<Expense>(sortBy: [SortDescriptor(\.date, order: .reverse)])
      )
      if scenario == .categoryPicker {
        #expect(
          expenses.map { $0.category?.name } == ["Shopping", "Groceries", "Transport", "Shopping"]
        )
        #expect(expenses.allSatisfy { $0.category != nil && $0.date < now })
      } else {
        #expect(expenses.isEmpty)
      }
    }
  }
}
