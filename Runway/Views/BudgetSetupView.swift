import Foundation
import SwiftData
import SwiftUI

/// Sets up a new budget on first launch, or edits the saved one from Settings. The logic lives in
/// `BudgetDraft`; this view only binds to it.
struct BudgetSetupView: View {
  /// The budget being edited, or `nil` to create one.
  let budget: Budget?
  let screenshotScenario: ScreenshotScenario?

  @Environment(\.modelContext) private var modelContext
  @Environment(\.dismiss) private var dismiss
  @Query private var expenses: [Expense]
  @State private var draft: BudgetDraft
  @State private var showsSaveError = false
  @State private var saveErrorMessage = ""
  /// Set while the confirm dialog for a period length or payday change is open.
  @State private var schedulePreview: ScheduleChangePreview?

  init(budget: Budget?, screenshotScenario: ScreenshotScenario? = nil) {
    self.budget = budget
    self.screenshotScenario = screenshotScenario
    if let budget {
      var draft = BudgetDraft(budget: budget)
      screenshotScenario?.prepare(&draft)
      _draft = State(initialValue: draft)
    } else {
      _draft = State(initialValue: BudgetDraft(periodStart: Calendar.current.startOfDay(for: .now)))
    }
  }

  private var calendar: Calendar { .current }

  var body: some View {
    let issues = draft.issues
    ScrollViewReader { proxy in
      Form {
        Section {
          NavigationLink("Categories") {
            CategoriesView()
          }
        }

        Section {
          LabeledContent("Available this period") {
            Text(draft.availableCents.map { Money.format(cents: $0) } ?? "—")
              .fontWeight(.semibold)
              .foregroundStyle(draft.showsLowAvailableWarning ? Color.red : Color.primary)
          }
          if draft.showsLowAvailableWarning {
            Label(
              "Bills and savings use up all of your spendable money. You can still save.",
              systemImage: "exclamationmark.triangle.fill"
            )
            .font(.footnote)
            .foregroundStyle(.orange)
          }
          if let budget, draft.changesAvailable(of: budget) {
            Label(
              "New amounts apply from today. Earlier days keep the allowance they had.",
              systemImage: "calendar.badge.clock"
            )
            .font(.footnote)
          }
        } footer: {
          Text("Spendable minus bills and savings, spread across the days of the period.")
        }

        Section {
          Picker("Period", selection: $draft.periodLength) {
            ForEach(PeriodLength.allCases, id: \.self) { length in
              Text(length.title).tag(length)
            }
          }
          .pickerStyle(.segmented)
          DatePicker("Starts on", selection: $draft.periodStart, displayedComponents: .date)
        } header: {
          Text("Pay period")
        } footer: {
          if let budget, draft.changesSchedule(of: budget, calendar: calendar) {
            Text("Saving ends the current period today and starts a new one.")
          } else {
            Text("Pick a payday. Each period starts on that day.")
          }
        }

        Section {
          AmountField(
            "Spendable per period",
            text: $draft.spendableText,
            issue: issues[.spendable],
            locale: draft.locale
          )
          AmountField(
            "Income (optional)",
            text: $draft.incomeText,
            issue: issues[.income],
            locale: draft.locale
          )
          Button("Use Income") {
            draft.useIncomeForSpendable()
          }
          .disabled(!draft.canUseIncome)
        } header: {
          Text("Spendable")
        } footer: {
          Text("What you can spend each period, before bills and savings.")
        }
        .id("spendable")

        Section {
          ForEach($draft.bills) { $bill in
            BillRow(
              bill: $bill,
              nameIssue: issues[.billName(bill.id)],
              amountIssue: issues[.billAmount(bill.id)],
              locale: draft.locale
            )
          }
          .onDelete { offsets in
            draft.bills.remove(atOffsets: offsets)
          }
          Button("Add Bill", systemImage: "plus") {
            draft.addBill()
          }
        } header: {
          Text("Fixed bills")
        } footer: {
          Text("Each amount comes out of every period. Swipe left to remove a bill.")
        }

        Section {
          AmountField(
            "Savings per period",
            text: $draft.savingsText,
            issue: issues[.savings],
            locale: draft.locale
          )
        } header: {
          Text("Savings")
        }

        Section {
          Toggle("Carry over leftovers", isOn: $draft.carryoverEnabled)
          if let date = carryoverChangeDate {
            Label(carryoverChangeText(date), systemImage: "calendar.badge.clock")
              .font(.footnote)
          }
        } footer: {
          Text("Leftovers or overspending roll into the next period. Changes apply next period.")
        }
        .id("carryover")
      }
      .task {
        let options = LaunchOptions(arguments: ProcessInfo.processInfo.arguments)
        guard let target = options.screenshotScrollTo else { return }
        do {
          try await Task.sleep(for: .milliseconds(300))
        } catch {
          return
        }
        proxy.scrollTo(target, anchor: .top)
      }
    }
    .navigationTitle(budget == nil ? "Set Up Budget" : "Budget")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if budget != nil {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
        }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save", action: requestSave)
          .disabled(!draft.canSave)
      }
    }
    .confirmationDialog(
      "Start a New Period?",
      isPresented: showsScheduleConfirmation,
      titleVisibility: .visible,
      presenting: schedulePreview
    ) { _ in
      Button("Start New Period Today", action: save)
      Button("Cancel", role: .cancel) {}
    } message: { preview in
      Text(scheduleChangeMessage(preview))
    }
    .alert("Couldn't Save", isPresented: $showsSaveError) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(saveErrorMessage)
    }
    .task {
      guard screenshotScenario == .budgetChangePeriod else { return }
      // Let the sheet finish presenting before opening the dialog.
      do {
        try await Task.sleep(for: .milliseconds(600))
      } catch {
        return
      }
      requestSave()
    }
  }

  // MARK: - Mid-period changes

  private var carryoverChangeDate: Date? {
    guard let budget else { return nil }
    return draft.carryoverChangeDate(for: budget, now: .now, calendar: calendar)
  }

  private func carryoverChangeText(_ date: Date) -> String {
    let day = date.formatted(.dateTime.month(.abbreviated).day())
    let change = draft.carryoverEnabled ? "on" : "off"
    return "Carryover turns \(change) when the next period starts, on \(day). "
      + "This period keeps its carry-in."
  }

  private var showsScheduleConfirmation: Binding<Bool> {
    Binding(
      get: { schedulePreview != nil },
      set: { if !$0 { schedulePreview = nil } }
    )
  }

  /// Saves, first asking for confirmation when a period length or payday change would end the
  /// current period.
  private func requestSave() {
    if let budget,
      let preview = draft.schedulePreview(
        for: budget,
        expenses: expenses.map { ExpenseSnapshot($0) },
        now: .now,
        calendar: calendar
      )
    {
      schedulePreview = preview
    } else {
      save()
    }
  }

  private func scheduleChangeMessage(_ preview: ScheduleChangePreview) -> String {
    let engine = AllowanceEngine(calendar: calendar)
    let format = Date.FormatStyle.dateTime.month(.abbreviated).day()
    let newEnd = engine.lastDay(of: preview.newPeriod).formatted(format)
    let endingLast = engine.lastDay(of: preview.endingPeriod).formatted(format)
    var lines = ["A new period starts today and runs through \(newEnd)."]
    if preview.endingPeriod.isPartial {
      let days = engine.dayCount(from: preview.endingPeriod.start, to: preview.endingPeriod.end)
      lines.append(
        "The current period ends early, after \(endingLast). Its money is cut to the \(days) "
          + "days it ran."
      )
    } else {
      lines.append("The previous period ended on \(endingLast).")
    }
    let amount = Money.format(cents: abs(preview.leftoverCents))
    let isOver = preview.leftoverCents < 0
    switch (preview.carriesOver, isOver) {
    case (true, false):
      lines.append("Its \(amount) left over carries into the new period.")
    case (true, true):
      lines.append("Its \(amount) of overspending carries into the new period.")
    case (false, false):
      lines.append("Carryover is off, so its \(amount) left over doesn't carry over.")
    case (false, true):
      lines.append("Carryover is off, so its \(amount) of overspending doesn't carry over.")
    }
    lines.append("Earlier days keep their history.")
    return lines.joined(separator: " ")
  }

  private func save() {
    let calendar = Calendar.current
    if let budget {
      guard draft.apply(to: budget, now: .now, calendar: calendar) else { return }
    } else {
      guard draft.insertBudget(into: modelContext, calendar: calendar) != nil else { return }
    }
    do {
      try modelContext.save()
      // On first launch, the root switches to the main screen once the budget exists.
      if budget != nil {
        dismiss()
      }
    } catch {
      modelContext.rollback()
      saveErrorMessage = error.localizedDescription
      showsSaveError = true
    }
  }
}

/// A labeled dollar amount text field with an inline validation message. The label wraps rather
/// than truncates, and sits above the field at accessibility text sizes. A valid amount is
/// reformatted as currency when the field loses focus.
private struct AmountField: View {
  let title: LocalizedStringKey
  @Binding var text: String
  var issue: BudgetDraft.Issue?
  var locale: Locale

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @FocusState private var isFocused: Bool

  init(
    _ title: LocalizedStringKey,
    text: Binding<String>,
    issue: BudgetDraft.Issue?,
    locale: Locale
  ) {
    self.title = title
    _text = text
    self.issue = issue
    self.locale = locale
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 4) {
          label
          field
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        HStack(spacing: 12) {
          label
          Spacer(minLength: 0)
          field
            .multilineTextAlignment(.trailing)
            .frame(minWidth: 80, maxWidth: 140, alignment: .trailing)
        }
      }
      if let issue {
        IssueText(issue: issue)
      }
    }
    .onChange(of: isFocused) { _, focused in
      guard !focused else { return }
      text = BudgetDraft.displayText(for: text, locale: locale)
    }
  }

  private var label: some View {
    Text(title)
      .fixedSize(horizontal: false, vertical: true)
      // The text field already carries the title for VoiceOver.
      .accessibilityHidden(true)
      .layoutPriority(1)
  }

  private var field: some View {
    TextField(title, text: $text, prompt: Text("$0.00"))
      .keyboardType(.decimalPad)
      .focused($isFocused)
  }
}

private struct BillRow: View {
  @Binding var bill: BudgetDraft.Bill
  var nameIssue: BudgetDraft.Issue?
  var amountIssue: BudgetDraft.Issue?
  var locale: Locale

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField("Name", text: $bill.name, prompt: Text("Bill name"))
      if let nameIssue {
        IssueText(issue: nameIssue)
      }
      AmountField("Amount", text: $bill.amountText, issue: amountIssue, locale: locale)
      Picker("Due day", selection: $bill.dueDay) {
        Text("None").tag(Int?.none)
        ForEach(1...31, id: \.self) { day in
          Text(day, format: .number).tag(Int?.some(day))
        }
      }
    }
    .padding(.vertical, 4)
  }
}

private struct IssueText: View {
  let issue: BudgetDraft.Issue

  var body: some View {
    Text(issue.message)
      .font(.footnote)
      .foregroundStyle(.red)
  }
}

extension PeriodLength {
  var title: LocalizedStringKey {
    switch self {
    case .weekly: "Weekly"
    case .biweekly: "Biweekly"
    case .monthly: "Monthly"
    }
  }
}

#Preview("Editing") {
  let container = try! RunwayModelContainer.make(inMemory: true)
  let budget = try! ScreenshotScenario.setupFilled.seed(
    into: container.mainContext,
    now: .now,
    calendar: .current
  )
  return NavigationStack {
    BudgetSetupView(budget: budget)
  }
  .modelContainer(container)
}
