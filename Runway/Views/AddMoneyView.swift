import Foundation
import SwiftData
import SwiftUI

/// Adds one-off money, like a bonus or gift, to the current period. It counts from today, so it
/// raises today's allowance and what's left this period without changing earlier days.
struct AddMoneyView: View {
  let budget: Budget

  @Environment(\.modelContext) private var modelContext
  @Environment(\.dismiss) private var dismiss
  @State private var amountText: String
  @State private var note: String
  @State private var errorMessage: String?

  /// `filled` starts with a sample gift, for screenshots.
  init(budget: Budget, filled: Bool = false) {
    self.budget = budget
    _amountText = State(initialValue: filled ? "150" : "")
    _note = State(initialValue: filled ? "Birthday gift" : "")
  }

  private var parsed: BudgetDraft.ParsedAmount {
    BudgetDraft.parseAmount(amountText)
  }

  /// The amount to add, if it's a valid amount above zero.
  private var cents: Int? {
    guard case .cents(let cents) = parsed, cents > 0 else { return nil }
    return cents
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Amount", text: $amountText, prompt: Text("$0.00"))
            .keyboardType(.decimalPad)
          if case .failure(let issue) = parsed {
            Text(issue.message)
              .font(.footnote)
              .foregroundStyle(.red)
          }
          TextField("Note", text: $note, prompt: Text("Bonus, gift, refund…"))
        } footer: {
          Text("Added to this period from today. It raises today's allowance and what's left.")
        }
      }
      .navigationTitle("Add Money")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Add", action: save)
            .disabled(cents == nil)
        }
      }
      .alert("Couldn't Add Money", isPresented: showsError) {
        Button("OK", role: .cancel) { errorMessage = nil }
      } message: {
        Text(errorMessage ?? "")
      }
    }
  }

  private var showsError: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )
  }

  private func save() {
    guard let cents else { return }
    budget.addExtraMoney(cents: cents, note: note, now: .now, calendar: .current)
    do {
      try modelContext.save()
      dismiss()
    } catch {
      modelContext.rollback()
      errorMessage = error.localizedDescription
    }
  }
}
