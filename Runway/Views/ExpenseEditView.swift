import Foundation
import SwiftData
import SwiftUI

/// Edits a saved expense from History with the quick-log form: amount, refund, category, note,
/// and a date inside the expense's own period through now. Delete hands the expense back to
/// History, which deletes it and offers Undo.
struct ExpenseEditView: View {
  let expense: Expense
  let period: BudgetPeriod
  let now: Date
  let onDelete: (Expense) -> Void

  @Environment(\.modelContext) private var modelContext
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var draft: ExpenseDraft
  @State private var category: Category?
  @State private var showsCategory = false
  @State private var errorMessage: String?

  init(
    expense: Expense,
    period: BudgetPeriod,
    now: Date,
    onDelete: @escaping (Expense) -> Void
  ) {
    self.expense = expense
    self.period = period
    self.now = now
    self.onDelete = onDelete
    _draft = State(initialValue: ExpenseDraft(expense: expense))
    _category = State(initialValue: expense.category)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Amount (USD)", text: $draft.amountText)
            .keyboardType(.decimalPad)
            .frame(minHeight: 44)
            .accessibilityLabel("Amount in US dollars")
            .accessibilityHint(
              "Required. Enter a positive amount; use Refund for money returned."
            )
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
            showsCategory = true
          } label: {
            if dynamicTypeSize.isAccessibilitySize {
              VStack(alignment: .leading, spacing: 8) {
                Text("Category")
                Text(categoryName)
              }
              .frame(minHeight: 44)
            } else {
              LabeledContent("Category", value: categoryName)
                .frame(minHeight: 44)
            }
          }
          .accessibilityHint("Choose a category, with recent categories first.")
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
        } footer: {
          Text("The date stays within this expense's budget period, through today.")
        }
        Section {
          Button(role: .destructive) {
            onDelete(expense)
            dismiss()
          } label: {
            Label("Delete Expense", systemImage: "trash")
              .frame(minHeight: 44)
          }
          .accessibilityHint("Deletes this expense. You can undo for a few seconds.")
        }
        if let errorMessage {
          Text(errorMessage)
            .foregroundStyle(.red)
        }
      }
      .scrollDismissesKeyboard(.interactively)
      .navigationTitle("Edit Expense")
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
            .accessibilityHint("Saves your changes and updates History and Today.")
        }
      }
      .navigationDestination(isPresented: $showsCategory) {
        CategoryPicker { selected in
          category = selected
          showsCategory = false
        }
      }
    }
  }

  private var categoryName: String {
    category?.name ?? "Other"
  }

  private var datePicker: some View {
    DatePicker(
      "Date",
      selection: $draft.date,
      in: ExpenseDraft.allowedDates(in: period, now: now),
      displayedComponents: .date
    )
    .datePickerStyle(.compact)
    .frame(minHeight: 44)
    .accessibilityLabel("Expense date")
    .accessibilityHint("Choose a date in this expense's budget period, through today.")
  }

  private func save() {
    do {
      let updated = try draft.update(
        expense,
        using: CategoryService(context: modelContext),
        category: category,
        period: period,
        now: now
      )
      guard updated else { return }
      try modelContext.save()
      dismiss()
    } catch {
      modelContext.rollback()
      errorMessage = error.localizedDescription
    }
  }
}
