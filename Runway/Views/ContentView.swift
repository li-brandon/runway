import Foundation
import SwiftData
import SwiftUI

struct ContentView: View {
  let budget: Budget

  @Query(sort: \Expense.date, order: .reverse) private var expenses: [Expense]
  @State private var showsSetup: Bool

  init(budget: Budget, showsSetup: Bool = false) {
    self.budget = budget
    _showsSetup = State(initialValue: showsSetup)
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day())
          .font(.headline)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal)

        LabeledContent(
          "Available this period",
          value: Money.format(cents: budget.availablePerPeriodCents)
        )
        .padding()

        if expenses.isEmpty {
          ContentUnavailableView(
            "Nothing Logged Yet",
            systemImage: "dollarsign.circle",
            description: Text("Expenses you log will show up here.")
          )
        } else {
          List(expenses) { expense in
            LabeledContent(
              expense.note.isEmpty ? "Expense" : expense.note,
              value: Money.format(cents: expense.amountCents)
            )
          }
        }
      }
      .navigationTitle("Runway")
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button("Settings", systemImage: "gearshape") {
            showsSetup = true
          }
        }
      }
      .sheet(isPresented: $showsSetup) {
        NavigationStack {
          BudgetSetupView(budget: budget)
        }
      }
    }
  }
}

#Preview {
  let container = try! RunwayModelContainer.make(inMemory: true)
  let budget = try! ScreenshotScenario.setupFilled.seed(
    into: container.mainContext,
    now: .now,
    calendar: .current
  )
  return ContentView(budget: budget!)
    .modelContainer(container)
}
