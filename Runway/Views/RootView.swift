import SwiftData
import SwiftUI

/// Shows budget setup until a budget exists (see `AppRoute`), then the main screen.
struct RootView: View {
  @Query(sort: \Budget.periodStart) private var budgets: [Budget]

  /// Opens setup over the main screen on launch. Used for CI screenshots.
  let opensSetupOnLaunch: Bool

  // Explicit because the private `@Query` makes the memberwise initializer private.
  init(opensSetupOnLaunch: Bool = false) {
    self.opensSetupOnLaunch = opensSetupOnLaunch
  }

  var body: some View {
    if AppRoute(hasBudget: !budgets.isEmpty) == .main, let budget = budgets.first {
      ContentView(budget: budget, showsSetup: opensSetupOnLaunch)
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
