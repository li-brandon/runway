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
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          VStack(alignment: .leading, spacing: 12) {
            Text("Remaining today")
              .font(.headline)
            Text(Money.format(cents: allowance.remainingTodayCents))
              .font(.largeTitle.bold())
              .accessibilityLabel("Remaining today")
              .accessibilityValue(Money.format(cents: allowance.remainingTodayCents))
            Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day())
              .font(.subheadline)
              .foregroundStyle(.secondary)
            Button {
              showsQuickLog = true
            } label: {
              Label("Log Expense", systemImage: "plus")
                .frame(maxWidth: .infinity, minHeight: 44)
                .multilineTextAlignment(.center)
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityHint("Opens the expense amount keypad.")
          }
          .padding()
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16)
          )

          VStack(alignment: .leading, spacing: 12) {
            Text("Today")
              .font(.headline)
            if expenses.isEmpty {
              ContentUnavailableView(
                "Nothing Logged Yet",
                systemImage: "dollarsign.circle",
                description: Text("Expenses you log will show up here.")
              )
            } else {
              VStack(alignment: .leading, spacing: 12) {
                ForEach(expenses) { expense in
                  if expense.id != expenses.first?.id {
                    Divider()
                  }
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
              .padding()
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 16)
              )
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical)
      }
      .background(Color(.systemGroupedBackground))
      .safeAreaInset(edge: .bottom) {
        if let undo {
          undoBanner(undo)
        }
      }
      .navigationTitle("Runway")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button("Settings", systemImage: "gearshape") {
            showsSetup = true
          }
          .frame(minWidth: 44, minHeight: 44)
        }
      }
      .sensoryFeedback(.success, trigger: saveFeedback)
      .task(id: undo?.expiresAt) {
        guard let deadline = undo?.expiresAt else { return }
        let delay = max(0, deadline.timeIntervalSinceNow)
        do {
          try await Task.sleep(for: .seconds(delay))
          if undo?.expiresAt == deadline { undo = nil }
        } catch {}
      }
      .task {
        if opensQuickLog {
          showsQuickLog = true
        } else if screenshotScenario == .todayUndo, undo == nil, let expense = expenses.first {
          // Let CI launch settle before starting the normal five-second undo window.
          try? await Task.sleep(for: .seconds(3))
          undo = ExpenseUndo(expense: expense, now: .now)
        }
      }
      .sheet(isPresented: $showsQuickLog) {
        QuickExpenseView(
          budget: budget,
          filled: screenshotScenario == .quickLogFilled || screenshotScenario == .quickLogNote,
          focusesNote: screenshotScenario == .quickLogNote
        ) { expense in
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

  private var opensQuickLog: Bool {
    switch screenshotScenario {
    case .quickLogEmpty, .quickLogFilled, .quickLogNote:
      true
    default:
      false
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
