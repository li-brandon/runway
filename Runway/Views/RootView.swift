import SwiftData
import SwiftUI

/// Keeps Today behind the initial setup sheet, then shows the saved budget.
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
      TodayEmptyView(opensSetup: screenshotScenario != .todayNoBudget)
    }
  }
}

#Preview("First launch") {
  RootView()
    .modelContainer(try! RunwayModelContainer.make(inMemory: true))
}

struct TodayEmptyView: View {
  @State private var showsSetup: Bool

  init(opensSetup: Bool = true) {
    _showsSetup = State(initialValue: opensSetup)
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        ContentUnavailableView {
          Label("Your runway starts here", systemImage: "dollarsign.circle")
        } description: {
          Text("Set up a budget to see what you can spend today.")
        } actions: {
          Button("Set up budget") { showsSetup = true }
            .buttonStyle(.borderedProminent)
            .frame(minHeight: 44)
        }
      }
      .navigationTitle("Today")
      .sheet(isPresented: $showsSetup) {
        NavigationStack {
          BudgetSetupView(budget: nil)
            .toolbar {
              ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { showsSetup = false }
              }
            }
        }
      }
    }
  }
}
