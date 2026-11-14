import Foundation
import SwiftData
import SwiftUI

/// Every credit card, soonest due first. Tap to edit, swipe to delete.
struct CreditCardsView: View {
  /// Opens the editor on the first card, for screenshots.
  var opensFirstCard = false

  @Environment(\.modelContext) private var modelContext
  @Query private var cards: [CreditCard]
  @State private var editor: CreditCardEditorRequest?
  @State private var deleting: CreditCard?
  @State private var showsDelete = false
  @State private var errorMessage = ""
  @State private var showsError = false

  private var calendar: Calendar { .current }

  var body: some View {
    let now = Date.now
    let sorted = CreditCardDates.sorted(cards, now: now, calendar: calendar)
    List {
      if sorted.isEmpty {
        ContentUnavailableView(
          "No Credit Cards",
          systemImage: "creditcard",
          description: Text("Add a card to keep its statement balance and due date in one place.")
        )
      } else {
        Section {
          ForEach(sorted) { card in
            Button {
              editor = CreditCardEditorRequest(card: card)
            } label: {
              CreditCardRow(card: card, now: now, calendar: calendar)
            }
            .tint(.primary)
            .swipeActions {
              Button("Delete", role: .destructive) {
                deleting = card
                showsDelete = true
              }
            }
          }
        } footer: {
          Text("Card payments you log don't count as spending. Purchases still do.")
        }
      }
    }
    .navigationTitle("Credit Cards")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("Add Card", systemImage: "plus") {
          editor = CreditCardEditorRequest(card: nil)
        }
        .frame(minWidth: 44, minHeight: 44)
      }
    }
    .sheet(item: $editor) { request in
      NavigationStack {
        CreditCardEditView(card: request.card)
      }
    }
    .confirmationDialog(
      "Delete card?",
      isPresented: $showsDelete,
      titleVisibility: .visible,
      presenting: deleting
    ) { card in
      Button("Delete Card", role: .destructive) {
        modelContext.delete(card)
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
    } message: { card in
      Text(CreditCardEditView.deletionMessage(name: card.name))
    }
    .alert("Couldn't Delete Card", isPresented: $showsError) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(errorMessage)
    }
    .task {
      guard opensFirstCard, let first = sorted.first else { return }
      editor = CreditCardEditorRequest(card: first)
    }
  }
}

private struct CreditCardEditorRequest: Identifiable {
  let id = UUID()
  let card: CreditCard?
}

/// A card's name, statement balance, due date, days left, and any stale or autopay note.
private struct CreditCardRow: View {
  let card: CreditCard
  let now: Date
  let calendar: Calendar

  var body: some View {
    let due = card.nextDueDate(now: now, calendar: calendar)
    let daysLeft = CreditCardDates.daysLeft(until: due, now: now, calendar: calendar)
    let dueText = due.formatted(.dateTime.month(.abbreviated).day())
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
      Text("Due \(dueText), \(Self.text(daysLeft: daysLeft))")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      if card.autopay {
        Label("Autopay", systemImage: "arrow.triangle.2.circlepath")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if card.hasStaleBalance(now: now, calendar: calendar) {
        Label("Balance may be out of date", systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }

  private var name: some View {
    Text(card.name)
      .font(.headline)
  }

  @ViewBuilder
  private var balance: some View {
    if let cents = card.statementBalanceCents {
      AmountText(cents: cents, accessibilityTitle: "Statement balance")
    } else {
      Text("No statement balance")
        .foregroundStyle(.secondary)
    }
  }

  static func text(daysLeft: Int) -> String {
    switch daysLeft {
    case 0: "due today"
    case 1: "1 day left"
    default: "\(daysLeft) days left"
    }
  }
}

/// Adds or edits a card. An existing card can also log a payment or be deleted.
struct CreditCardEditView: View {
  let card: CreditCard?

  @Environment(\.modelContext) private var modelContext
  @Environment(\.dismiss) private var dismiss
  @State private var draft: CreditCardDraft
  @State private var showsPayment = false
  @State private var showsDelete = false
  @State private var errorMessage: String?

  init(card: CreditCard?) {
    self.card = card
    _draft = State(initialValue: CreditCardDraft(card: card))
  }

  static func deletionMessage(name: String) -> String {
    "Delete \(name)? Payments you logged stay in your history and still don't count as spending."
  }

  var body: some View {
    Form {
      Section {
        TextField("Name", text: $draft.name, prompt: Text("Card name"))
          .frame(minHeight: 44)
        if draft.trimmedName.isEmpty {
          Text("Enter a card name.")
            .font(.footnote)
            .foregroundStyle(.red)
        }
        dayPicker("Statement day", selection: $draft.statementDay)
        dayPicker("Due day", selection: $draft.dueDay)
        Toggle("Autopay", isOn: $draft.autopay)
          .frame(minHeight: 44)
      }
      Section {
        AmountField(
          "Statement balance",
          text: $draft.statementBalanceText,
          issue: draft.statementBalance.issue,
          locale: draft.locale
        )
        .frame(minHeight: 44)
        AmountField(
          "Current balance",
          text: $draft.currentBalanceText,
          issue: draft.currentBalance.issue,
          locale: draft.locale
        )
        .frame(minHeight: 44)
      } header: {
        Text("Balances")
      } footer: {
        Text(
          "Leave a balance blank if you don't know it. One you enter is up to date until the next "
            + "statement day."
        )
      }
      if card != nil {
        Section {
          Button("Log Payment", systemImage: "creditcard") {
            showsPayment = true
          }
          .frame(minHeight: 44)
          Button("Delete Card", systemImage: "trash", role: .destructive) {
            showsDelete = true
          }
          .frame(minHeight: 44)
        }
      }
      if let errorMessage {
        Text(errorMessage)
          .foregroundStyle(.red)
      }
    }
    .navigationTitle(card == nil ? "Add Card" : "Edit Card")
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
    .sheet(isPresented: $showsPayment) {
      if let card {
        CardPaymentView(card: card)
      }
    }
    .confirmationDialog("Delete card?", isPresented: $showsDelete, titleVisibility: .visible) {
      Button("Delete Card", role: .destructive, action: delete)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(Self.deletionMessage(name: card?.name ?? ""))
    }
  }

  private func dayPicker(_ title: LocalizedStringKey, selection: Binding<Int>) -> some View {
    Picker(title, selection: selection) {
      ForEach(1...31, id: \.self) { day in
        Text("\(day)").tag(day)
      }
    }
    .frame(minHeight: 44)
  }

  private func save() {
    guard draft.save(to: card, in: modelContext, now: .now) != nil else { return }
    persist()
  }

  private func delete() {
    guard let card else { return }
    modelContext.delete(card)
    persist()
  }

  private func persist() {
    do {
      try modelContext.save()
      dismiss()
    } catch {
      modelContext.rollback()
      errorMessage = error.localizedDescription
    }
  }
}

/// Logs a payment toward a card: an expense flagged as a payment, so it never counts as spending.
private struct CardPaymentView: View {
  let card: CreditCard

  @Environment(\.modelContext) private var modelContext
  @Environment(\.dismiss) private var dismiss
  @State private var amountText = ""
  @State private var date = Date.now
  @State private var errorMessage: String?

  private var parsed: BudgetDraft.ParsedAmount {
    BudgetDraft.parseAmount(amountText)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          AmountField(
            "Amount",
            text: $amountText,
            issue: parsed.issue,
            locale: .autoupdatingCurrent
          )
          .frame(minHeight: 44)
          DatePicker("Date", selection: $date, in: ...Date.now, displayedComponents: .date)
            .frame(minHeight: 44)
        } footer: {
          Text("Payments show with your expenses but don't change what's left to spend.")
        }
        if let errorMessage {
          Text(errorMessage)
            .foregroundStyle(.red)
        }
      }
      .navigationTitle("Pay \(card.name)")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
            .frame(minHeight: 44)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save", action: save)
            .frame(minHeight: 44)
            .disabled((parsed.amountCents ?? 0) <= 0)
        }
      }
    }
  }

  private func save() {
    guard let cents = parsed.amountCents, cents > 0 else { return }
    do {
      try card.logPayment(cents: cents, date: date, in: modelContext, now: .now)
      try modelContext.save()
      dismiss()
    } catch {
      modelContext.rollback()
      errorMessage = error.localizedDescription
    }
  }
}
