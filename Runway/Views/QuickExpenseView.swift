import Foundation
import SwiftData
import SwiftUI

struct QuickExpenseView: View {
  let budget: Budget
  let focusesNote: Bool
  let onSave: (Expense) -> Void

  @Environment(\.modelContext) private var modelContext
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var draft: ExpenseDraft
  @State private var category: Category?
  @State private var showsCategory = false
  @State private var errorMessage: String?

  private enum Field: Hashable {
    case amount
    case note
  }

  @FocusState private var focusedField: Field?

  init(
    budget: Budget,
    filled: Bool = false,
    focusesNote: Bool = false,
    onSave: @escaping (Expense) -> Void
  ) {
    self.budget = budget
    self.focusesNote = focusesNote
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
      ScrollViewReader { proxy in
        Form {
          Section {
            TextField("Amount (USD)", text: $draft.amountText)
              .keyboardType(.decimalPad)
              .focused($focusedField, equals: .amount)
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
              focusedField = nil
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
            .id("category-and-note")
            TextField("Note (optional)", text: $draft.note, axis: .vertical)
              .focused($focusedField, equals: .note)
              .frame(minHeight: 44)
            Group {
              if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                  Text("Date")
                  datePicker.labelsHidden()
                }
              } else {
                datePicker
              }
            }
            .id("expense-date")
          }
          if let errorMessage {
            Text(errorMessage)
              .foregroundStyle(.red)
          }
        }
        .scrollDismissesKeyboard(.interactively)
        .task(id: focusedField) {
          guard focusedField == nil else { return }
          do {
            try await Task.sleep(for: .milliseconds(350))
          } catch {
            return
          }
          withAnimation {
            proxy.scrollTo("expense-date", anchor: .bottom)
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
          if focusesNote {
            focusedField = .note
            do {
              try await Task.sleep(for: .milliseconds(500))
            } catch {
              return
            }
            proxy.scrollTo("category-and-note", anchor: .top)
          } else {
            focusedField = .amount
          }
        }
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
