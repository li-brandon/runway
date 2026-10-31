import Foundation
import SwiftData
import SwiftUI

/// The current period's extra money and fixed bills. Bills can be marked paid (at the planned
/// amount or another one) or skipped; either way the change counts from today.
struct PeriodMoneyView: View {
  let budget: Budget
  /// The time Today treats as now; fixed for screenshots.
  let now: Date

  @Environment(\.modelContext) private var modelContext
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var showsAddMoney = false
  /// The bill whose paid amount is being entered.
  @State private var payingBill: FixedBill?
  @State private var paidText = ""
  @State private var errorMessage: String?

  private var calendar: Calendar { .current }

  private var period: BudgetPeriod {
    AllowanceEngine(calendar: calendar).period(containing: now, of: BudgetSnapshot(budget))
  }

  /// Ordered by due day (none last), then name, like setup.
  private var bills: [FixedBill] {
    budget.fixedBills.sorted { lhs, rhs in
      (lhs.dueDay ?? 32, lhs.name) < (rhs.dueDay ?? 32, rhs.name)
    }
  }

  var body: some View {
    let period = self.period
    let extras = budget.extraMoneyItems(in: period)
    let lastExtraID = extras.last?.persistentModelID
    return NavigationStack {
      ScrollViewReader { proxy in
        List {
          Section {
            ForEach(extras) { extra in
              extraRow(extra)
                .id(extra.persistentModelID)
            }
            .onDelete { offsets in
              remove(offsets.map { extras[$0] })
            }
            Button("Add Money", systemImage: "plus") {
              showsAddMoney = true
            }
          } header: {
            Text("Extra money")
          } footer: {
            Text("One-off money, like a bonus or gift. It counts from the day it's added.")
          }

          Section {
            if bills.isEmpty {
              Text("No fixed bills.")
                .foregroundStyle(.secondary)
            } else {
              ForEach(bills) { bill in
                billRow(bill, status: budget.status(of: bill, in: period))
              }
            }
          } header: {
            Text("Bills this period")
          } footer: {
            Text(
              "Bills are set aside every period, so paying one early changes nothing. Skipping "
                + "one, or paying a different amount, changes what's left from today."
            )
          }
          .id("bills")
        }
        .task {
          let options = LaunchOptions(arguments: ProcessInfo.processInfo.arguments)
          let target = options.screenshotScrollTo
          guard target == "bills" || target == "extras" else { return }
          do {
            try await Task.sleep(for: .milliseconds(300))
          } catch {
            return
          }
          if target == "bills" {
            proxy.scrollTo("bills", anchor: .top)
          } else if let lastExtraID {
            // The row's bottom, so a long note can't push its amount off screen.
            proxy.scrollTo(lastExtraID, anchor: .bottom)
          }
        }
      }
      .navigationTitle("This Period")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            dismiss()
          }
        }
      }
      .sheet(isPresented: $showsAddMoney) {
        AddMoneyView(budget: budget)
      }
      .alert(
        "Mark \(payingBill?.name ?? "Bill") Paid",
        isPresented: showsPaidAmount,
        presenting: payingBill
      ) { bill in
        TextField("Amount paid", text: $paidText)
          .keyboardType(.decimalPad)
        Button("Mark Paid") {
          markPaid(bill)
        }
        Button("Cancel", role: .cancel) {}
      } message: { bill in
        Text(
          "Enter what you paid. It's \(Money.format(cents: bill.amountCents)) in your budget; "
            + "any difference changes what's left from today."
        )
      }
      .alert("Couldn't Change This Period", isPresented: showsError) {
        Button("OK", role: .cancel) { errorMessage = nil }
      } message: {
        Text(errorMessage ?? "")
      }
    }
  }

  // MARK: - Rows

  private func extraRow(_ extra: ExtraMoney) -> some View {
    let note = extra.note.isEmpty ? "Extra money" : extra.note
    let title = VStack(alignment: .leading, spacing: 4) {
      Text(note)
      Text(extra.date, format: .dateTime.month(.abbreviated).day())
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    let amount = AmountText(cents: extra.amountCents)
    return Group {
      if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 4) {
          title
          amount
        }
      } else {
        HStack(alignment: .firstTextBaseline) {
          title
          Spacer(minLength: 12)
          amount
        }
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func billRow(_ bill: FixedBill, status: BillStatus) -> some View {
    Menu {
      Button("Mark Paid", systemImage: "checkmark.circle") {
        paidText = BudgetDraft.text(fromCents: bill.amountCents)
        payingBill = bill
      }
      Button("Skip This Period", systemImage: "forward") {
        setStatus(.skipped, of: bill)
      }
      if status != .unpaid {
        Button("Mark Unpaid", systemImage: "arrow.uturn.backward") {
          setStatus(.unpaid, of: bill)
        }
      }
    } label: {
      let title = VStack(alignment: .leading, spacing: 4) {
        Text(bill.name)
        Label(statusText(status, of: bill), systemImage: statusSymbol(status))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      let amount = AmountText(cents: bill.amountCents)
      Group {
        if dynamicTypeSize.isAccessibilitySize {
          VStack(alignment: .leading, spacing: 4) {
            title
            amount
          }
        } else {
          HStack(alignment: .firstTextBaseline) {
            title
            Spacer(minLength: 12)
            amount
          }
        }
      }
      .foregroundStyle(.primary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    // Plain so the row keeps primary and secondary text rather than the accent tint.
    .menuStyle(.button)
    .buttonStyle(.plain)
    .accessibilityHint("Marks the bill paid or skipped for this period.")
  }

  private func statusText(_ status: BillStatus, of bill: FixedBill) -> String {
    switch status {
    case .unpaid:
      guard let dueDay = bill.dueDay else { return "Not paid yet" }
      return "Not paid yet, due on day \(dueDay)"
    case .paid(let cents):
      guard cents != bill.amountCents else { return "Paid" }
      return "Paid \(Money.format(cents: cents))"
    case .skipped:
      return "Skipped this period"
    }
  }

  private func statusSymbol(_ status: BillStatus) -> String {
    switch status {
    case .unpaid: "circle"
    case .paid: "checkmark.circle.fill"
    case .skipped: "forward.fill"
    }
  }

  // MARK: - Actions

  private var showsPaidAmount: Binding<Bool> {
    Binding(
      get: { payingBill != nil },
      set: { if !$0 { payingBill = nil } }
    )
  }

  private var showsError: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )
  }

  private func markPaid(_ bill: FixedBill) {
    guard case .cents(let cents) = BudgetDraft.parseAmount(paidText) else {
      errorMessage = "Enter a dollar amount, like 12.34."
      return
    }
    setStatus(.paid(cents: cents), of: bill)
  }

  private func setStatus(_ status: BillStatus, of bill: FixedBill) {
    budget.setStatus(status, of: bill, now: .now, calendar: calendar)
    saveOrRollBack()
  }

  private func remove(_ extras: [ExtraMoney]) {
    for extra in extras {
      budget.removeExtraMoney(extra)
    }
    saveOrRollBack()
  }

  private func saveOrRollBack() {
    do {
      try modelContext.save()
    } catch {
      modelContext.rollback()
      errorMessage = error.localizedDescription
    }
  }
}
