import SwiftData
import SwiftUI

/// Shows budget setup until a budget exists (see `AppRoute`), then the main screen.
struct RootView: View {
  @Query(sort: \Budget.periodStart) private var budgets: [Budget]

  /// Opens the requested sample screen on launch. Used for CI screenshots.
  let screenshotScenario: ScreenshotScenario?

  // Explicit because the private `@Query` makes the memberwise initializer private.
  init(screenshotScenario: ScreenshotScenario? = nil) {
    self.screenshotScenario = screenshotScenario
  }

  var body: some View {
    if screenshotScenario == .categories {
      NavigationStack {
        CategoriesView()
      }
    } else if screenshotScenario == .categoryPicker {
      CategoryPickerHost()
    } else if AppRoute(hasBudget: !budgets.isEmpty) == .main, let budget = budgets.first {
      ContentView(
        budget: budget,
        showsSetup: screenshotScenario == .setupFilled || screenshotScenario == .setupWarning,
        screenshotScenario: screenshotScenario
      )
    } else {
      NavigationStack {
        BudgetSetupView(budget: nil)
      }
    }
  }
}

#Preview("First launch") {
  RootView()
    .modelContainer(try! RunwayModelContainer.make(inMemory: true))
}
