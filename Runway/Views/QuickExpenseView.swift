import Foundation
import SwiftData
import SwiftUI

struct QuickExpenseView: View {
  let budget: Budget
  let onSave: (Expense) -> Void

  @Environment(\.modelContext) private var modelContext
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var draft: ExpenseDraft
  @State private var category: Category?
  @State private var showsCategory = false
  @State private var errorMessage: String?
  @FocusState private var amountFocused: Bool

  init(budget: Budget, filled: Bool = false, onSave: @escaping (Expense) -> Void) {
    self.budget = budget
    self.onSave = onSave
    var draft = ExpenseDraft()
    if filled {
      draft.amountText = "12.50"
      draft.note = "Lunch with Sam"
    }
    _draft = State(initialValue: draft)
  }

  private var periodStart: Date {
    AllowanceEngine(calendar: .current)
      .period(containing: .now, of: BudgetSnapshot(budget)).start
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Amount (USD)", text: $draft.amountText)
            .keyboardType(.decimalPad)
            .focused($amountFocused)
            .frame(minHeight: 44)
            .accessibilityLabel("Amount in US dollars")
            .accessibilityHint("Required. Enter a positive amount; use Refund for money returned.")
          Toggle("Refund", isOn: $draft.isRefund)
            .frame(minHeight: 44)
            .accessibilityHint("Subtracts this amount from your spending.")
        } footer: {
          if let message = draft.validationMessage {
            Text(message)
          }
        }
        Section {
          Button {
            amountFocused = false
            showsCategory = true
          } label: {
            if dynamicTypeSize.isAccessibilitySize {
              VStack(alignment: .leading, spacing: 8) {
                Text("Category")
                Text(category?.name ?? "Other")
              }
              .frame(minHeight: 44)
            } else {
              LabeledContent("Category", value: category?.name ?? "Other")
                .frame(minHeight: 44)
            }
          }
          .accessibilityHint("Optional. Choose a category, with recent categories first.")
          TextField("Note (optional)", text: $draft.note, axis: .vertical)
            .frame(minHeight: 44)
          if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
              Text("Date")
              datePicker.labelsHidden()
            }
          } else {
            datePicker
          }
        }
        if let errorMessage {
          Text(errorMessage)
            .foregroundStyle(.red)
        }
      }
      .navigationTitle("Log Expense")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .frame(minHeight: 44)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save", action: save)
            .frame(minHeight: 44)
            .disabled(draft.amountCents == nil)
            .accessibilityHint("Saves this expense and updates today's remaining amount.")
        }
      }
      .navigationDestination(isPresented: $showsCategory) {
        CategoryPicker { selected in
          category = selected
          showsCategory = false
        }
      }
      .task {
        if !draft.amountText.isEmpty {
          let categories = try? CategoryService(context: modelContext).categories()
          category = categories?.first { $0.name == "Food" }
        }
        amountFocused = true
      }
    }
  }

  private var datePicker: some View {
    DatePicker(
      "Date",
      selection: $draft.date,
      in: ExpenseDraft.allowedDates(periodStart: periodStart, now: .now),
      displayedComponents: .date
    )
    .datePickerStyle(.compact)
    .frame(minHeight: 44)
    .accessibilityLabel("Expense date")
    .accessibilityHint("Choose a date in the current budget period, through today.")
  }

  private func save() {
    do {
      let now = Date.now
      let created = try draft.createExpense(
        using: CategoryService(context: modelContext),
        category: category,
        periodStart: periodStart,
        now: now
      )
      guard let expense = created else { return }
      try modelContext.save()
      onSave(expense)
      dismiss()
    } catch {
      modelContext.rollback()
      errorMessage = error.localizedDescription
    }
  }
}
