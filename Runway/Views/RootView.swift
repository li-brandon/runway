import Foundation
import SwiftData
import SwiftUI

/// Keeps Today behind the initial setup sheet, then shows the saved budget.
struct RootView: View {
  @Query(sort: \Budget.periodStart) private var budgets: [Budget]

  /// Opens the requested sample screen on launch. Used for CI screenshots.
  let screenshotScenario: ScreenshotScenario?

  /// Bumped after an import or reset to rebuild every view, closing any open sheets. Views may
  /// hold models that no longer exist, and reading those can crash.
  @State private var dataGeneration = 0
  /// Stays the same across updates, so `dataDidReplace` compares equal and readers don't update.
  /// An older copy of the action still works, since it writes to the same `@State` storage.
  @State private var dataReplaceActionID = UUID()

  // Explicit because the private `@Query` makes the memberwise initializer private.
  init(screenshotScenario: ScreenshotScenario? = nil) {
    self.screenshotScenario = screenshotScenario
  }

  var body: some View {
    Group {
      if screenshotScenario == .categories {
        NavigationStack {
          CategoriesView()
        }
      } else if screenshotScenario == .categoryPicker {
        CategoryPickerHost()
      } else if screenshotScenario?.opensPrivacyData == true {
        NavigationStack {
          PrivacyDataView(screenshotScenario: screenshotScenario)
        }
      } else if AppRoute(hasBudget: !budgets.isEmpty) == .main, let budget = budgets.first {
        ContentView(
          budget: budget,
          showsSetup: screenshotScenario?.opensBudgetSetup == true,
          screenshotScenario: screenshotScenario
        )
      } else {
        TodayEmptyView(opensSetup: screenshotScenario != .todayNoBudget)
      }
    }
    .id(dataGeneration)
    .environment(
      \.dataDidReplace,
      DataReplaceAction(id: dataReplaceActionID) { dataGeneration += 1 }
    )
  }
}

#Preview("First launch") {
  RootView()
    .modelContainer(try! RunwayModelContainer.make(inMemory: true))
}

struct TodayEmptyView: View {
  @State private var state: TodayEmptyState

  init(opensSetup: Bool = true) {
    _state = State(initialValue: TodayEmptyState(opensSetup: opensSetup))
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        ContentUnavailableView {
          Label("Your runway starts here", systemImage: "dollarsign.circle")
        } description: {
          Text("Set up a budget to see what you can spend today.")
        } actions: {
          Button("Set up budget") { state.openSetup() }
            .buttonStyle(.borderedProminent)
            .frame(minHeight: 44)
        }
      }
      .navigationTitle("Today")
      .sheet(isPresented: $state.showsSetup) {
        NavigationStack {
          BudgetSetupView(budget: nil)
            .toolbar {
              ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { state.showsSetup = false }
              }
            }
        }
      }
    }
  }
}
