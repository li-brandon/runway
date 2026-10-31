import Foundation
import SwiftData
import SwiftUI

/// Edits a bill mark dated before the budget from History: its status, paid amount, and a date
/// within `period` through now. `period` ends at the budget's start, so the mark stays out of every
/// period's figures. Delete hands it back to History, which offers Undo.
struct BillPaymentEditView: View {
  let mark: BillPayment
  let period: BudgetPeriod
  let now: Date
  let onDelete: (BillPayment) -> Void

  @Environment(\.modelContext) private var modelContext
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var draft: BillPaymentDraft
  @State private var errorMessage: String?

  init(
    mark: BillPayment,
    period: BudgetPeriod,
    now: Date,
    onDelete: @escaping (BillPayment) -> Void
  ) {
    self.mark = mark
    self.period = period
    self.now = now
    self.onDelete = onDelete
    _draft = State(initialValue: BillPaymentDraft(mark: mark))
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text(mark.bill?.name ?? "Deleted bill")
            .font(.headline)
            .frame(minHeight: 44)
          Picker("Status", selection: $draft.status) {
            statusLabel("Paid").tag(BillPaymentDraft.Status.paid)
            statusLabel("Skipped").tag(BillPaymentDraft.Status.skipped)
            statusLabel("Unpaid").tag(BillPaymentDraft.Status.unpaid)
          }
          .pickerStyle(.segmented)
          .frame(minHeight: 44)
          .accessibilityLabel("Status")
          if draft.status == .paid {
            TextField("Amount paid", text: $draft.amountText, prompt: Text("$0.00"))
              .keyboardType(.decimalPad)
              .frame(minHeight: 44)
            if case .failure(let issue) = draft.parsed {
              Text(issue.message)
                .font(.footnote)
                .foregroundStyle(.red)
            }
          }
          if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
              Text("Date")
              datePicker.labelsHidden()
            }
          } else {
            datePicker
          }
        } footer: {
          Text("The date stays before your budget started, so this counts toward no period.")
        }
        Section {
          Button(role: .destructive) {
            onDelete(mark)
            dismiss()
          } label: {
            Label("Delete Bill Entry", systemImage: "trash")
              .frame(minHeight: 44)
          }
          .accessibilityHint("Deletes this bill entry. You can undo for a few seconds.")
        }
        if let errorMessage {
          Text(errorMessage)
            .foregroundStyle(.red)
        }
      }
      .scrollDismissesKeyboard(.interactively)
      .navigationTitle("Edit Bill Entry")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .frame(minHeight: 44)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save", action: save)
            .frame(minHeight: 44)
            .disabled(draft.paidCents == nil)
        }
      }
    }
  }

  private func statusLabel(_ title: String) -> some View {
    Text(title)
      .lineLimit(1)
      .minimumScaleFactor(TextScaling.minimumFactor)
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
    .accessibilityLabel("Bill entry date")
  }

  private func save() {
    guard draft.update(mark, period: period, now: now, calendar: .current) else { return }
    do {
      try modelContext.save()
      dismiss()
    } catch {
      modelContext.rollback()
      errorMessage = error.localizedDescription
    }
  }
}
