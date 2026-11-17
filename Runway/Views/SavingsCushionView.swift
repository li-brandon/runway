import Foundation
import SwiftData
import SwiftUI

/// The cushion checking needs for upcoming card payments, what to move from savings, and by
/// when. Lists savings and checking accounts: tap to edit, swipe to delete.
struct SavingsCushionView: View {
  @Environment(\.modelContext) private var modelContext
  @Query private var cards: [CreditCard]
  @Query(sort: \CashAccount.name) private var accounts: [CashAccount]
  @Query(sort: \Budget.periodStart) private var budgets: [Budget]
  @State private var editor: CashAccountEditorRequest?
  @State private var showsSettings = false
  @State private var deleting: CashAccount?
  @State private var showsDelete = false
  @State private var errorMessage = ""
  @State private var showsError = false

  private var calendar: Calendar { .current }

  var body: some View {
    let now = Date.now
    let budget = budgets.first
    let cushion = SavingsCushion(
      budget: budget,
      cards: cards,
      accounts: accounts,
      now: now,
      calendar: calendar
    )
    let payday = CardPayoffSchedule.nextPayday(after: now, of: budget, calendar: calendar)
    List {
      Section {
        CushionSummary(cushion: cushion, payday: payday)
      } footer: {
        Text(
          "Covers every card's statement balance by its due date. Balances are the ones you "
            + "entered."
        )
      }

      Section {
        if accounts.isEmpty {
          Text("Add your checking and savings accounts to see what to move.")
            .foregroundStyle(.secondary)
        }
        ForEach(accounts) { account in
          Button {
            editor = CashAccountEditorRequest(account: account)
          } label: {
            CashAccountRow(account: account)
          }
          .tint(.primary)
          .swipeActions {
            Button("Delete", role: .destructive) {
              deleting = account
              showsDelete = true
            }
          }
        }
        Button("Add Account", systemImage: "plus") {
          editor = CashAccountEditorRequest(account: nil)
        }
        .frame(minHeight: 44)
      } header: {
        Text("Accounts")
      } footer: {
        Text("Only accounts marked Checking or Savings count toward the cushion.")
      }

      Section {
        if let budget {
          LabeledContent("Extra buffer") {
            Text(budget.cushionBufferCents.map { Money.format(cents: $0) } ?? "None")
          }
          .frame(minHeight: 44)
          LabeledContent("Reserve in Left to spend today") {
            Text(budget.reservesCushion ? "On" : "Off")
          }
          .frame(minHeight: 44)
          Button("Edit Settings", systemImage: "slider.horizontal.3") {
            showsSettings = true
          }
          .frame(minHeight: 44)
        } else {
          Text("Save your budget to add a buffer or reserve the cushion in Left to spend today.")
            .foregroundStyle(.secondary)
        }
      } header: {
        Text("Settings")
      } footer: {
        Text(
          "The buffer is kept in checking on top of card payments. Reserving holds back what's "
            + "still to move, so it isn't counted as money to spend."
        )
      }
    }
    .navigationTitle("Savings Cushion")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(item: $editor) { request in
      NavigationStack {
        CashAccountEditView(account: request.account)
      }
    }
    .sheet(isPresented: $showsSettings) {
      if let budget {
        NavigationStack {
          CushionSettingsView(budget: budget)
        }
      }
    }
    .confirmationDialog(
      "Delete account?",
      isPresented: $showsDelete,
      titleVisibility: .visible,
      presenting: deleting
    ) { account in
      Button("Delete Account", role: .destructive) {
        modelContext.delete(account)
        do {
          try modelContext.save()
        } catch {
          modelContext.rollback()
          errorMessage = error.localizedDescription
          showsError = true
        }
        deleting = nil
      }
      Button("Cancel", role: .cancel) {
        deleting = nil
      }
    } message: { account in
      Text("Delete \(account.name)? It stops counting toward the cushion.")
    }
    .alert("Couldn't Delete Account", isPresented: $showsError) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(errorMessage)
    }
  }
}

private struct CashAccountEditorRequest: Identifiable {
  let id = UUID()
  let account: CashAccount?
}

/// The cushion, what checking and savings hold, and what to move by when, or that checking
/// covers it. Warns when savings can't cover the transfer.
private struct CushionSummary: View {
  let cushion: SavingsCushion
  let payday: Date?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      figure("Cushion needed", cents: cushion.cushionCents)
      figure("In checking", cents: cushion.checkingCents)
      figure("In savings", cents: cushion.savingsCents)
      if cushion.bufferCents > 0 {
        Text("Includes a \(Money.format(cents: cushion.bufferCents)) buffer.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      Divider()
      if cushion.transferCents == 0 {
        Label("Checking covers every upcoming card payment.", systemImage: "checkmark.circle")
          .foregroundStyle(.green)
      } else {
        Label(transferText, systemImage: "arrow.left.arrow.right")
          .font(.headline)
        if let paydayText {
          Text(paydayText)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      if cushion.shortfallCents > 0 {
        Label(
          "Savings is \(Money.format(cents: cushion.shortfallCents)) short of what to move.",
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.footnote)
        .foregroundStyle(.orange)
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 4)
  }

  private var transferText: String {
    let amount = Money.format(cents: cushion.transferCents)
    guard let date = cushion.transferBy else {
      return "Move \(amount) from Savings to Checking."
    }
    let day = date.formatted(.dateTime.month(.abbreviated).day())
    return "Move \(amount) from Savings to Checking by \(day)."
  }

  /// Whether the transfer can wait for the next paycheck.
  private var paydayText: String? {
    guard let payday, cushion.transferBy != nil else { return nil }
    let day = payday.formatted(.dateTime.month(.abbreviated).day())
    return cushion.isTransferDue(before: payday)
      ? "That's before your next payday, \(day)."
      : "Your next payday, \(day), comes first."
  }

  private func figure(_ title: LocalizedStringKey, cents: Int) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .firstTextBaseline) {
        Text(title)
        Spacer(minLength: 12)
        AmountText(cents: cents, accessibilityTitle: title)
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
        AmountText(cents: cents, accessibilityTitle: title)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

/// An account's name, role, and balance.
private struct CashAccountRow: View {
  let account: CashAccount

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline) {
          name
          Spacer(minLength: 12)
          balance
        }
        VStack(alignment: .leading, spacing: 4) {
          name
          balance
        }
      }
      Text(account.role.title)
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }

  private var name: some View {
    Text(account.name)
      .font(.headline)
  }

  @ViewBuilder
  private var balance: some View {
    if let cents = account.balanceCents {
      AmountText(cents: cents, accessibilityTitle: "Balance")
    } else {
      Text("No balance")
        .foregroundStyle(.secondary)
    }
  }
}

/// Adds or edits an account: its name, whether it counts as checking or savings, and its balance.
private struct CashAccountEditView: View {
  let account: CashAccount?

  @Environment(\.modelContext) private var modelContext
  @Environment(\.dismiss) private var dismiss
  @State private var draft: CashAccountDraft
  @State private var errorMessage: String?

  init(account: CashAccount?) {
    self.account = account
    _draft = State(initialValue: CashAccountDraft(account: account))
  }

  var body: some View {
    Form {
      Section {
        TextField("Name", text: $draft.name, prompt: Text("Account name"))
          .frame(minHeight: 44)
        if draft.trimmedName.isEmpty {
          Text("Enter an account name.")
            .font(.footnote)
            .foregroundStyle(.red)
        }
        Picker("Counts as", selection: $draft.role) {
          ForEach(CashAccountRole.allCases, id: \.self) { role in
            Text(role.title).tag(role)
          }
        }
        .frame(minHeight: 44)
      }
      Section {
        AmountField(
          "Balance",
          text: $draft.balanceText,
          issue: draft.balance.issue,
          locale: draft.locale
        )
        .frame(minHeight: 44)
      } footer: {
        Text("Leave the balance blank if you don't know it. It counts as $0.")
      }
      if let errorMessage {
        Text(errorMessage)
          .foregroundStyle(.red)
      }
    }
    .navigationTitle(account == nil ? "Add Account" : "Edit Account")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }
          .frame(minHeight: 44)
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save", action: save)
          .frame(minHeight: 44)
          .disabled(!draft.canSave)
      }
    }
  }

  private func save() {
    guard draft.save(to: account, in: modelContext, now: .now) != nil else { return }
    do {
      try modelContext.save()
      dismiss()
    } catch {
      modelContext.rollback()
      errorMessage = error.localizedDescription
    }
  }
}

/// Edits the cushion's extra buffer and whether Left to spend today reserves the cushion.
private struct CushionSettingsView: View {
  let budget: Budget

  @Environment(\.modelContext) private var modelContext
  @Environment(\.dismiss) private var dismiss
  @State private var draft: CushionSettingsDraft
  @State private var errorMessage: String?

  init(budget: Budget) {
    self.budget = budget
    _draft = State(initialValue: CushionSettingsDraft(budget: budget))
  }

  var body: some View {
    Form {
      Section {
        AmountField(
          "Extra buffer",
          text: $draft.bufferText,
          issue: draft.buffer.issue,
          locale: draft.locale
        )
        .frame(minHeight: 44)
      } footer: {
        Text("Kept in checking on top of card payments. Leave blank for none.")
      }
      Section {
        Toggle("Reserve in Left to spend today", isOn: $draft.reservesCushion)
          .frame(minHeight: 44)
      } footer: {
        Text(
          "Holds back what's still to move to checking, spread over the rest of the period, "
            + "until checking covers the cushion."
        )
      }
      if let errorMessage {
        Text(errorMessage)
          .foregroundStyle(.red)
      }
    }
    .navigationTitle("Cushion Settings")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }
          .frame(minHeight: 44)
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save", action: save)
          .frame(minHeight: 44)
          .disabled(!draft.canSave)
      }
    }
  }

  private func save() {
    guard draft.save(to: budget) else { return }
    do {
      try modelContext.save()
      dismiss()
    } catch {
      modelContext.rollback()
      errorMessage = error.localizedDescription
    }
  }
}
