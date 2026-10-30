import Combine
import Foundation
import SwiftData
import SwiftUI
import UIKit

struct ContentView: View {
  let budget: Budget
  let screenshotScenario: ScreenshotScenario?

  @Environment(\.modelContext) private var modelContext
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.scenePhase) private var scenePhase
  @ScaledMetric(relativeTo: .largeTitle) private var amountSize = 80.0
  @State private var now = Date.now

  @Query(sort: \Expense.date, order: .reverse) private var expenses: [Expense]
  @State private var showsSetup: Bool

  @State private var showsQuickLog = false
  @State private var showsAddMoney = false
  @State private var showsPeriodMoney: Bool
  @State private var showsHistory: Bool
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
    _showsHistory = State(initialValue: screenshotScenario?.isHistory == true)
    _showsPeriodMoney = State(initialValue: screenshotScenario == .budgetChangeBills)
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          VStack(alignment: .leading, spacing: 8) {
            Text("Left to spend today")
              .font(.footnote)
            Text(Money.format(cents: allowance.remainingTodayCents))
              .font(.system(size: min(amountSize, 96), weight: .bold, design: .rounded))
              .lineLimit(1)
              .minimumScaleFactor(0.1)
              .frame(maxWidth: .infinity, alignment: .leading)
              .foregroundStyle(statusColor)
              .accessibilityLabel("Left to spend today")
              .accessibilityValue(Money.format(cents: allowance.remainingTodayCents))
            Label(status.title, systemImage: status.symbol)
              .font(.caption)
              .foregroundStyle(statusColor)
            Text(displayNow, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
              .font(.caption2)
              .foregroundStyle(.secondary)
            Text("Spent: \(Money.format(cents: allowance.spentTodayCents))")
              .font(.footnote)
              .accessibilityLabel("Spent today")
              .accessibilityValue(Money.format(cents: allowance.spentTodayCents))
            Text("Allowance: \(Money.format(cents: allowance.allowanceTodayCents))")
              .font(.footnote)
              .accessibilityLabel("Today's allowance")
              .accessibilityValue(Money.format(cents: allowance.allowanceTodayCents))
            Button {
              showsQuickLog = true
            } label: {
              Label("Log Expense", systemImage: "plus")
                .frame(maxWidth: .infinity, minHeight: 44)
                .multilineTextAlignment(.center)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Opens the expense amount keypad.")
          }
          .fixedSize(horizontal: false, vertical: true)
          .padding()
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16)
          )

          VStack(alignment: .leading, spacing: 4) {
            Text("Remaining this period: \(Money.format(cents: allowance.remainingPeriodCents))")
            Text("\(allowance.daysLeft) days left, including today")
            if showsCarryIn {
              Text("Carry-in from last period: \(Money.format(cents: allowance.carryInCents))")
            }
            if allowance.extraCents != 0 {
              Text("Extra money this period: \(Money.format(cents: allowance.extraCents))")
            }
            if let pendingCarryoverText {
              Text(pendingCarryoverText)
            }
          }
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

          periodActions

          VStack(alignment: .leading, spacing: 12) {
            Text("Today's expenses")
              .font(.headline)
            if expensesToday.isEmpty {
              Text("Nothing logged today.")
                .foregroundStyle(.secondary)
            } else {
              ForEach(expensesToday) { expense in
                expenseRow(expense)
                Divider()
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical)
        .padding(.bottom, dynamicTypeSize.isAccessibilitySize ? 32 : 16)
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
        ToolbarItem(placement: .topBarLeading) {
          Button("History", systemImage: "clock.arrow.circlepath") {
            showsHistory = true
          }
          .frame(minWidth: 44, minHeight: 44)
          .accessibilityHint("Shows past days and periods, where you can edit expenses.")
        }
        ToolbarItem(placement: .primaryAction) {
          Button("Settings", systemImage: "gearshape") {
            showsSetup = true
          }
          .frame(minWidth: 44, minHeight: 44)
        }
      }
      .navigationDestination(isPresented: $showsHistory) {
        HistoryView(budget: budget, now: displayNow, screenshotScenario: screenshotScenario)
      }
      .sensoryFeedback(.success, trigger: saveFeedback)
      .onChange(of: scenePhase) { _, phase in
        guard phase == .active else { return }
        // The time zone may have changed while the app was in the background.
        adoptCurrentTimeZone()
        now = .now
      }
      .onReceive(
        NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)
          .receive(on: RunLoop.main)
      ) { _ in
        adoptCurrentTimeZone()
        now = .now
      }
      .onReceive(
        NotificationCenter.default.publisher(for: NSNotification.Name.NSSystemTimeZoneDidChange)
          .receive(on: RunLoop.main)
      ) { _ in
        adoptCurrentTimeZone()
        now = .now
      }
      .task(id: now) {
        guard screenshotScenario?.todayDate == nil else { return }
        let midnight = nextMidnight(after: now, calendar: .current)
        do {
          try await Task.sleep(for: .seconds(max(0, midnight.timeIntervalSinceNow)))
          now = .now
        } catch {}
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
        adoptCurrentTimeZone()
        if opensQuickLog {
          showsQuickLog = true
        } else if screenshotScenario == .budgetChangeAddMoney {
          showsAddMoney = true
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
          BudgetSetupView(budget: budget, screenshotScenario: screenshotScenario)
        }
      }
      .sheet(isPresented: $showsAddMoney) {
        AddMoneyView(budget: budget, filled: screenshotScenario == .budgetChangeAddMoney)
      }
      .sheet(isPresented: $showsPeriodMoney) {
        PeriodMoneyView(budget: budget, now: displayNow)
      }
    }
  }

  /// Add Money and This Period, side by side or stacked at accessibility sizes. Disabled before
  /// the budget's first day, when there's no period to add to.
  private var periodActions: some View {
    let stacked = AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
    let inline = AnyLayout(HStackLayout(spacing: 12))
    let layout = dynamicTypeSize.isAccessibilitySize ? stacked : inline
    let hasStarted = allowance.period.contains(displayNow)
    return layout {
      Button {
        showsAddMoney = true
      } label: {
        Label("Add Money", systemImage: "plus.circle")
          .frame(minHeight: 44)
      }
      .accessibilityHint("Adds one-off money, like a bonus or gift, to this period.")
      Button {
        showsPeriodMoney = true
      } label: {
        Label("This Period", systemImage: "list.bullet.rectangle")
          .frame(minHeight: 44)
      }
      .accessibilityHint("Shows extra money and lets you mark bills paid or skipped.")
    }
    .buttonStyle(.bordered)
    .disabled(!hasStarted)
  }

  /// Re-expresses the budget's paydays in the current time zone after the device moves, so the
  /// day boundary follows where the user is without shifting paydays.
  private func adoptCurrentTimeZone() {
    NSTimeZone.resetSystemTimeZone()
    guard budget.adoptTimeZone(of: .current) else { return }
    do {
      try modelContext.save()
    } catch {
      modelContext.rollback()
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
      now: displayNow
    )
  }

  private var displayNow: Date { screenshotScenario?.todayDate ?? now }

  private var status: TodayStatus { TodayStatus(allowance) }

  private var statusColor: Color {
    switch status {
    case .normal: .primary
    case .nearLimit, .noAllowance: .orange
    case .over: .red
    }
  }

  private var showsCarryIn: Bool {
    AllowanceEngine(calendar: .current).isCarryoverEnabled(
      atBoundary: allowance.periodStart,
      budget: BudgetSnapshot(budget)
    )
  }

  /// Says when a carryover change made this period starts to apply.
  private var pendingCarryoverText: String? {
    let engine = AllowanceEngine(calendar: .current)
    let snapshot = BudgetSnapshot(budget)
    guard let pending = engine.pendingCarryoverChange(budget: snapshot, now: displayNow) else {
      return nil
    }
    let day = pending.effectiveAt.formatted(.dateTime.month(.abbreviated).day())
    let change = pending.enabled ? "on" : "off"
    return "Carryover turns \(change) next period, on \(day)"
  }

  private var expensesToday: [Expense] {
    todayExpenses(expenses, now: displayNow, calendar: .current)
  }

  private func expenseRow(_ expense: Expense) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if let category = expense.category {
        CategoryLabel(category: category)
      }
      if !expense.note.isEmpty {
        Text(expense.note)
      }
      HStack {
        if expense.amountCents < 0 {
          Label("Refund", systemImage: "arrow.uturn.backward")
        }
        Text(Money.format(cents: expense.amountCents))
          .fontWeight(.semibold)
      }
      Text(expense.date, format: .dateTime.hour().minute())
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .combine)
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
