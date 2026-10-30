import Foundation
import SwiftData
import SwiftUI

/// Edits saved extra money from History's Before budget section: amount, note, and a date within
/// `period` through now. Delete hands it back to History, which removes it like This Period does.
struct ExtraMoneyEditView: View {
  let extra: ExtraMoney
  let period: BudgetPeriod
  let now: Date
  let onDelete: (ExtraMoney) -> Void

  @Environment(\.modelContext) private var modelContext
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var draft: ExtraMoneyDraft
  @State private var errorMessage: String?

  init(
    extra: ExtraMoney,
    period: BudgetPeriod,
    now: Date,
    onDelete: @escaping (ExtraMoney) -> Void
  ) {
    self.extra = extra
    self.period = period
    self.now = now
    self.onDelete = onDelete
    _draft = State(initialValue: ExtraMoneyDraft(extra: extra))
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Amount", text: $draft.amountText, prompt: Text("$0.00"))
            .keyboardType(.decimalPad)
            .frame(minHeight: 44)
          if case .failure(let issue) = draft.parsed {
            Text(issue.message)
              .font(.footnote)
              .foregroundStyle(.red)
          }
          TextField("Note", text: $draft.note, prompt: Text("Bonus, gift, refund…"))
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
          if period == .beforeBudget {
            Text("Choosing a date since your budget started moves this money into that period.")
          } else {
            Text("The date stays within this money's budget period, through today.")
          }
        }
        Section {
          Button(role: .destructive) {
            onDelete(extra)
            dismiss()
          } label: {
            Label("Delete Extra Money", systemImage: "trash")
              .frame(minHeight: 44)
          }
          .accessibilityHint("Deletes this extra money. This can't be undone.")
        }
        if let errorMessage {
          Text(errorMessage)
            .foregroundStyle(.red)
        }
      }
      .scrollDismissesKeyboard(.interactively)
      .navigationTitle("Edit Extra Money")
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
        }
      }
    }
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
    .accessibilityLabel("Extra money date")
  }

  private func save() {
    guard draft.update(extra, period: period, now: now, calendar: .current) else { return }
    do {
      try modelContext.save()
      dismiss()
    } catch {
      modelContext.rollback()
      errorMessage = error.localizedDescription
    }
  }
}
