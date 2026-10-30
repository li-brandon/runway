import Foundation
import SwiftData
import SwiftUI

/// Past days and periods for the saved budget. Every figure comes from `HistoryEngine` on each
/// render, so editing or deleting an expense updates later days, carryover, and Today.
struct HistoryView: View {
  let budget: Budget
  /// The time History treats as now; Today passes its own, fixed for screenshots.
  let now: Date
  let screenshotScenario: ScreenshotScenario?

  @Environment(\.modelContext) private var modelContext
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  @Query(
    sort: [
      SortDescriptor(\Expense.date, order: .reverse),
      SortDescriptor(\Expense.createdAt, order: .reverse),
    ]
  )
  private var expenses: [Expense]
  @Query(sort: [SortDescriptor(\Category.sortOrder), SortDescriptor(\Category.name)])
  private var categories: [Category]

  /// 0 shows the current period; each step back shows the one before it.
  @State private var periodOffset = 0
  @State private var editing: Expense?
  @State private var editNow = Date.now
  /// Only the latest delete can be undone; see `ExpenseUndoSlot`.
  @State private var undoSlot = ExpenseUndoSlot()
  @State private var errorMessage: String?

  // Explicit because the private `@Query` makes the memberwise initializer private.
  init(budget: Budget, now: Date, screenshotScenario: ScreenshotScenario? = nil) {
    self.budget = budget
    self.now = now
    self.screenshotScenario = screenshotScenario
  }

  private var calendar: Calendar { .current }

  private var engine: HistoryEngine { HistoryEngine(calendar: calendar) }

  private var page: HistoryPage {
    Self.makePage(
      budget: budget,
      expenses: expenses,
      periodOffset: periodOffset,
      now: now,
      calendar: calendar
    )
  }

  /// Everything one render computes, from `expenses` sorted newest first like the query. Static
  /// so tests can time it with the view's own inputs.
  static func makePage(
    budget: Budget,
    expenses: [Expense],
    periodOffset: Int,
    now: Date,
    calendar: Calendar
  ) -> HistoryPage {
    let engine = HistoryEngine(calendar: calendar)
    let periods = engine.periods(
      budget: BudgetSnapshot(budget),
      expenses: expenses.map { HistoryExpense<PersistentIdentifier?>($0) },
      now: now
    )
    let index = min(periodOffset, periods.count - 1)
    let expensesByDay = engine.itemsByDay(expenses, in: periods[index].period) { $0.date }
    return HistoryPage(periods: periods, index: index, expensesByDay: expensesByDay)
  }

  var body: some View {
    let page = self.page
    let all = page.periods
    let index = page.index
    let selected = page.selected
    // The carryover setting at the end of a completed period is the next period's at its start.
    let carriesOut = index > 0 && all[index - 1].carryoverEnabledAtStart
    let expensesByDay = page.expensesByDay
    // A List, so rows are created lazily as they scroll in, even with hundreds of expenses.
    return ScrollViewReader { proxy in
      List {
        Section {
          periodNavigator(selected, isOldest: index == all.count - 1)
        }
        summarySection(selected, carriesOut: carriesOut)
        categorySection(selected)
        ForEach(selected.days, id: \.date) { day in
          Section {
            daySummary(day)
              .id(day.date)
            ForEach(expensesByDay[day.date] ?? []) { expense in
              expenseRow(expense)
            }
          }
        }
      }
      .listStyle(.insetGrouped)
      .task {
        await prepareScreenshot(proxy: proxy, days: selected.days)
      }
    }
    .safeAreaInset(edge: .bottom) {
      if undoSlot.pending != nil {
        undoBanner()
      }
    }
    .navigationTitle("History")
    .navigationBarTitleDisplayMode(.inline)
    .task(id: undoSlot.pending?.expiresAt) {
      guard let deadline = undoSlot.pending?.expiresAt else { return }
      let delay = max(0, deadline.timeIntervalSinceNow)
      do {
        try await Task.sleep(for: .seconds(delay))
        undoSlot.expire(at: deadline)
      } catch {}
    }
    .sheet(item: $editing) { expense in
      ExpenseEditView(
        expense: expense,
        period: period(of: expense),
        now: editNow,
        onDelete: delete
      )
    }
    .alert("Couldn't Change Expense", isPresented: showsError) {
      Button("OK", role: .cancel) { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
  }

  // MARK: - Sections

  private func periodNavigator(
    _ period: HistoryPeriod<PersistentIdentifier?>,
    isOldest: Bool
  ) -> some View {
    let stacked = AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
    let inline = AnyLayout(HStackLayout(spacing: 12))
    let isStacked = dynamicTypeSize.isAccessibilitySize
    let layout = isStacked ? stacked : inline
    return VStack(alignment: .leading, spacing: 8) {
      Text(periodTitle(period.period))
        .font(.headline)
      Text(period.isCurrent ? "Current period, through today" : "Past period")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      layout {
        Button {
          periodOffset += 1
        } label: {
          navigatorLabel("Earlier", systemImage: "chevron.left", isStacked: isStacked)
        }
        .disabled(isOldest)
        .accessibilityLabel("Earlier period")
        Button {
          periodOffset = max(0, periodOffset - 1)
        } label: {
          navigatorLabel("Later", systemImage: "chevron.right", isStacked: isStacked)
        }
        .disabled(period.isCurrent)
        .accessibilityLabel("Later period")
      }
      .buttonStyle(.bordered)
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  /// One line at its natural width side by side; full width and free to wrap when stacked.
  private func navigatorLabel(
    _ title: String,
    systemImage: String,
    isStacked: Bool
  ) -> some View {
    Label(title, systemImage: systemImage)
      .lineLimit(isStacked ? nil : 1)
      .fixedSize(horizontal: !isStacked, vertical: true)
      .frame(maxWidth: isStacked ? .infinity : nil, minHeight: 44)
  }

  private func summarySection(
    _ period: HistoryPeriod<PersistentIdentifier?>,
    carriesOut: Bool
  ) -> some View {
    Section {
      valueRow(Money.format(cents: period.spentCents)) { Text("Spent") }
      valueRow(Money.format(cents: period.availableCents)) { Text("Available") }
      if period.extraCents != 0 {
        valueRow(Money.format(cents: period.extraCents)) { Text("Extra money") }
      }
      OverUnderLabel(remainingCents: period.remainingCents)
      valueRow("\(period.daysOver) of \(period.days.count)") { Text("Days over budget") }
      valueRow(carryInText(period)) { Text("Carry-in") }
      valueRow(carryOutText(period, carriesOut: carriesOut)) { Text("Carry-out") }
    } header: {
      Text("Summary")
    } footer: {
      if period.isCurrent {
        Text("Through today. Carry-out is set when the period ends.")
      }
    }
  }

  private func categorySection(_ period: HistoryPeriod<PersistentIdentifier?>) -> some View {
    let byID = Dictionary(
      categories.map { ($0.persistentModelID, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    let totals = Array(period.categories.enumerated())
    return Section {
      if totals.isEmpty {
        Text("No spending yet.")
          .foregroundStyle(.secondary)
          .id("categories")
      } else {
        ForEach(totals, id: \.element.categoryID) { offset, total in
          valueRow(Money.format(cents: total.spentCents)) {
            if let id = total.categoryID, let category = byID[id] {
              CategoryLabel(category: category)
            } else {
              Text("Uncategorized")
            }
          }
          .id(offset == 0 ? "categories" : "category-\(offset)")
        }
      }
    } header: {
      Text("By category")
    }
  }

  private func daySummary(_ day: HistoryDay) -> some View {
    let allowance = Text("Allowance: \(Money.format(cents: day.allowanceCents))")
    let spent = Text("Spent: \(Money.format(cents: day.spentCents))")
    return VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text(day.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
          .font(.headline)
        if day.isToday {
          Text("Today")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
      Group {
        if dynamicTypeSize.isAccessibilitySize {
          VStack(alignment: .leading, spacing: 6) {
            allowance
            spent
          }
        } else {
          HStack(alignment: .firstTextBaseline) {
            allowance
            Spacer(minLength: 12)
            spent
          }
        }
      }
      .font(.subheadline)
      OverUnderLabel(remainingCents: day.remainingCents)
    }
    .fixedSize(horizontal: false, vertical: true)
    .accessibilityElement(children: .combine)
  }

  private func expenseRow(_ expense: Expense) -> some View {
    Button {
      edit(expense)
    } label: {
      HistoryExpenseRow(expense: expense)
    }
    // Plain so the row keeps primary and secondary text rather than the accent tint.
    .buttonStyle(.plain)
    .swipeActions(edge: .trailing) {
      Button("Delete", systemImage: "trash", role: .destructive) {
        delete(expense)
      }
      Button("Edit", systemImage: "pencil") {
        edit(expense)
      }
      .tint(.blue)
    }
    .accessibilityHint("Opens the expense to edit or delete it.")
  }

  // MARK: - Rows

  /// A title and an amount side by side, stacked at accessibility sizes.
  @ViewBuilder
  private func valueRow<Title: View>(
    _ value: String,
    @ViewBuilder title: () -> Title
  ) -> some View {
    if dynamicTypeSize.isAccessibilitySize {
      VStack(alignment: .leading, spacing: 4) {
        title()
        Text(value)
          .fontWeight(.semibold)
      }
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityElement(children: .combine)
    } else {
      HStack(alignment: .firstTextBaseline) {
        title()
        Spacer(minLength: 12)
        Text(value)
          .fontWeight(.semibold)
          .multilineTextAlignment(.trailing)
      }
      .accessibilityElement(children: .combine)
    }
  }

  private func undoBanner() -> some View {
    let stacked = AnyLayout(VStackLayout(spacing: 8))
    let inline = AnyLayout(HStackLayout(spacing: 16))
    let layout = dynamicTypeSize.isAccessibilitySize ? stacked : inline
    return layout {
      Text("Expense deleted")
        .font(.headline)
      Button("Undo") {
        restore()
      }
      .frame(minWidth: 44, minHeight: 44)
      .accessibilityHint("Restores the expense you just deleted.")
    }
    .padding()
    .frame(maxWidth: .infinity)
    .background(.regularMaterial)
  }

  // MARK: - Text

  private func periodTitle(_ period: BudgetPeriod) -> String {
    let start = period.start.formatted(.dateTime.month(.abbreviated).day())
    let end = engine.lastDay(of: period).formatted(.dateTime.month(.abbreviated).day().year())
    return "\(start) – \(end)"
  }

  private func carryInText(_ period: HistoryPeriod<PersistentIdentifier?>) -> String {
    guard period.carryoverEnabledAtStart else { return "Off" }
    return Money.format(cents: period.carryInCents)
  }

  private func carryOutText(
    _ period: HistoryPeriod<PersistentIdentifier?>,
    carriesOut: Bool
  ) -> String {
    guard let carryOut = period.carryOutCents else { return "Pending" }
    guard carriesOut else { return "Off" }
    return Money.format(cents: carryOut)
  }

  // MARK: - Actions

  /// Editing keeps an expense inside the period it is dated in.
  private func period(of expense: Expense) -> BudgetPeriod {
    let snapshot = BudgetSnapshot(budget)
    return AllowanceEngine(calendar: calendar).period(containing: expense.date, of: snapshot)
  }

  private func edit(_ expense: Expense) {
    editNow = screenshotScenario?.todayDate ?? .now
    editing = expense
  }

  private func delete(_ expense: Expense) {
    editing = nil
    do {
      // Replaces any earlier deletion, which stays deleted without an undo.
      try undoSlot.delete(expense, in: modelContext, now: .now)
    } catch {
      modelContext.rollback()
      errorMessage = error.localizedDescription
    }
  }

  private func restore() {
    do {
      try undoSlot.undo(in: modelContext, now: .now)
    } catch {
      modelContext.rollback()
      errorMessage = error.localizedDescription
    }
  }

  private var showsError: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )
  }

  /// Opens the screen each History screenshot scenario needs, after launch settles.
  private func prepareScreenshot(proxy: ScrollViewProxy, days: [HistoryDay]) async {
    guard let screenshotScenario, screenshotScenario.isHistory else { return }
    let today = calendar.startOfDay(for: now)
    if screenshotScenario == .historyPeriodSummary || screenshotScenario == .history500 {
      periodOffset = 1
    }
    // Let the push from Today finish before presenting a sheet or scrolling.
    do {
      try await Task.sleep(for: .milliseconds(600))
    } catch {
      return
    }
    let yesterdaysLatest = expenses.first { $0.date < today }
    if screenshotScenario == .historyEdit, let yesterdaysLatest {
      edit(yesterdaysLatest)
    }
    let options = LaunchOptions(arguments: ProcessInfo.processInfo.arguments)
    if options.screenshotScrollTo == "categories" {
      proxy.scrollTo("categories", anchor: .top)
    } else if screenshotScenario == .historyList, let first = days.first {
      proxy.scrollTo(first.date, anchor: .top)
    } else if screenshotScenario == .history500, let oldest = page.selected.days.last {
      // The completed period's first day, below hundreds of expense rows.
      proxy.scrollTo(oldest.date, anchor: .top)
    }
  }
}

/// One render of History: every period newest first, the selected one, and its expenses by day.
struct HistoryPage {
  let periods: [HistoryPeriod<PersistentIdentifier?>]
  let index: Int
  let expensesByDay: [Date: [Expense]]

  var selected: HistoryPeriod<PersistentIdentifier?> { periods[index] }
}

/// Over or under with a symbol and words as well as color.
struct OverUnderLabel: View {
  let remainingCents: Int

  var body: some View {
    Label {
      Text(title)
        .fontWeight(remainingCents < 0 ? .semibold : .regular)
        .foregroundStyle(remainingCents < 0 ? Color.red : Color.primary)
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: symbol)
        .foregroundStyle(remainingCents < 0 ? Color.red : Color.secondary)
        .accessibilityHidden(true)
    }
  }

  private var title: String {
    if remainingCents < 0 {
      return "Over by \(Money.format(cents: -remainingCents))"
    }
    if remainingCents == 0 {
      return "On budget"
    }
    return "Under by \(Money.format(cents: remainingCents))"
  }

  private var symbol: String {
    if remainingCents < 0 { return "exclamationmark.triangle.fill" }
    if remainingCents == 0 { return "equal.circle" }
    return "checkmark.circle"
  }
}

/// One expense in History: category, amount (with a Refund label), note, and time.
struct HistoryExpenseRow: View {
  let expense: Expense

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if dynamicTypeSize.isAccessibilitySize {
        category
        amount
      } else {
        HStack(alignment: .firstTextBaseline) {
          category
          Spacer(minLength: 12)
          amount
        }
      }
      if !expense.note.isEmpty {
        Text(expense.note)
          .foregroundStyle(.secondary)
      }
      Text(expense.date, format: .dateTime.hour().minute())
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .foregroundStyle(.primary)
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var category: some View {
    if let category = expense.category {
      CategoryLabel(category: category)
    } else {
      Text("Uncategorized")
    }
  }

  private var amount: some View {
    HStack(spacing: 6) {
      if expense.amountCents < 0 {
        Label("Refund", systemImage: "arrow.uturn.backward")
          .font(.subheadline)
      }
      Text(Money.format(cents: expense.amountCents))
        .fontWeight(.semibold)
    }
  }
}
