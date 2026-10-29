import Foundation
import SwiftData
import SwiftUI

struct ContentView: View {
  let budget: Budget
  let screenshotScenario: ScreenshotScenario?

  @Environment(\.modelContext) private var modelContext
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  @Query(sort: \Expense.date, order: .reverse) private var expenses: [Expense]
  @State private var showsSetup: Bool

  @State private var showsQuickLog = false
  @State private var undo: ExpenseUndo?
  @State private var saveFeedback = 0
  @State private var errorMessage: String?

  init(
    budget: Budget,
    showsSetup: Bool = false,
    screenshotScenario: ScreenshotScenario? = nil
  ) {
    self.budget = budget
    self.screenshotScenario = screenshotScenario
    _showsSetup = State(initialValue: showsSetup)
  }

  var body: some View {
    NavigationStack {
      List {
        Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day())
          .font(.headline)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal)

        VStack(spacing: 12) {
          Text("Remaining today")
            .font(.headline)
          Text(Money.format(cents: allowance.remainingTodayCents))
            .font(.largeTitle.bold())
            .accessibilityLabel("Remaining today")
            .accessibilityValue(Money.format(cents: allowance.remainingTodayCents))
          Button("Log Expense", systemImage: "plus") {
            showsQuickLog = true
          }
          .buttonStyle(.borderedProminent)
          .frame(minHeight: 44)
          .accessibilityHint("Opens the expense amount keypad.")
        }
        .padding()

        if expenses.isEmpty {
          ContentUnavailableView(
            "Nothing Logged Yet",
            systemImage: "dollarsign.circle",
            description: Text("Expenses you log will show up here.")
          )
        } else {
          ForEach(expenses) { expense in
            if dynamicTypeSize.isAccessibilitySize {
              VStack(alignment: .leading, spacing: 8) {
                Text(expense.note.isEmpty ? "Expense" : expense.note)
                Text(Money.format(cents: expense.amountCents))
              }
            } else {
              LabeledContent(
                expense.note.isEmpty ? "Expense" : expense.note,
                value: Money.format(cents: expense.amountCents)
              )
            }
          }
        }
      }
      .navigationTitle("Runway")
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button("Settings", systemImage: "gearshape") {
            showsSetup = true
          }
          .frame(minWidth: 44, minHeight: 44)
        }
      }
      .sensoryFeedback(.success, trigger: saveFeedback)
      .safeAreaInset(edge: .bottom) {
        if let undo {
          undoBanner(undo)
        }
      }
      .task(id: undo?.expiresAt) {
        guard let deadline = undo?.expiresAt else { return }
        let delay = max(0, deadline.timeIntervalSinceNow)
        do {
          try await Task.sleep(for: .seconds(delay))
          if undo?.expiresAt == deadline { undo = nil }
        } catch {}
      }
      .task {
        if screenshotScenario == .quickLogEmpty || screenshotScenario == .quickLogFilled {
          showsQuickLog = true
        } else if screenshotScenario == .todayUndo, undo == nil, let expense = expenses.first {
          // Let CI launch settle before starting the normal five-second undo window.
          try? await Task.sleep(for: .seconds(3))
          undo = ExpenseUndo(expense: expense, now: .now)
        }
      }
      .sheet(isPresented: $showsQuickLog) {
        QuickExpenseView(budget: budget, filled: screenshotScenario == .quickLogFilled) { expense in
          undo = ExpenseUndo(expense: expense, now: .now)
          saveFeedback += 1
        }
      }
      .alert("Couldn't Undo Expense", isPresented: showsError) {
        Button("OK", role: .cancel) { errorMessage = nil }
      } message: {
        Text(errorMessage ?? "")
      }
      .sheet(isPresented: $showsSetup) {
        NavigationStack {
          BudgetSetupView(budget: budget)
        }
      }
    }
  }

  private var allowance: AllowanceResult {
    AllowanceEngine(calendar: .current).currentAllowance(
      budget: BudgetSnapshot(budget),
      expenses: expenses.map { ExpenseSnapshot($0) },
      now: .now
    )
  }

  private var showsError: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )
  }

  private func undoBanner(_ opportunity: ExpenseUndo) -> some View {
    let stacked = AnyLayout(VStackLayout(spacing: 8))
    let inline = AnyLayout(HStackLayout(spacing: 16))
    let layout = dynamicTypeSize.isAccessibilitySize ? stacked : inline
    return layout {
      Text("Expense saved")
        .font(.headline)
      Button("Undo") {
        do {
          try opportunity.undo(in: modelContext, now: .now)
          undo = nil
        } catch {
          modelContext.rollback()
          errorMessage = error.localizedDescription
        }
      }
      .frame(minWidth: 44, minHeight: 44)
      .accessibilityHint("Deletes the expense you just logged.")
    }
    .padding()
    .frame(maxWidth: .infinity)
    .background(.regularMaterial)
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
