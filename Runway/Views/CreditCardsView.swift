import Foundation
import SwiftData
import SwiftUI

/// Upcoming payments with the cash needed by each due date, this month's spend per card, and every
/// credit card, soonest due first. Tap a card to edit, swipe to delete.
struct CreditCardsView: View {
  /// Opens the editor on the first card, for screenshots.
  var opensFirstCard = false

  @Environment(\.modelContext) private var modelContext
  @Query private var cards: [CreditCard]
  @Query(sort: \Budget.periodStart) private var budgets: [Budget]
  @State private var editor: CreditCardEditorRequest?
  @State private var deleting: CreditCard?
  @State private var showsDelete = false
  @State private var errorMessage = ""
  @State private var showsError = false

  private var calendar: Calendar { .current }

  var body: some View {
    let now = Date.now
    let sorted = CreditCardDates.sorted(cards, now: now, calendar: calendar)
    let schedule = CardPayoffSchedule(
      cards: cards,
      now: now,
      nextPayday: CardPayoffSchedule.nextPayday(after: now, of: budgets.first, calendar: calendar),
      calendar: calendar
    )
    let spend = CardMonthlySpend.summary(
      of: cards.flatMap(\.payments),
      now: now,
      calendar: calendar
    )
    List {
      if sorted.isEmpty {
        ContentUnavailableView(
          "No Credit Cards",
          systemImage: "creditcard",
          description: Text("Add a card to keep its statement balance and due date in one place.")
        )
      } else {
        payoffSections(schedule)
        if !spend.isEmpty {
          Section {
            ForEach(spend) { item in
              CardSpendRow(spend: item)
            }
          } header: {
            Text("Spend This Month")
          } footer: {
            Text("Purchases on each card this month and last month. Payments aren't included.")
          }
        }
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
      Section {
        NavigationLink {
          SavingsCushionView()
        } label: {
          Label("Savings Cushion", systemImage: "banknote")
            .frame(minHeight: 44)
        }
      } footer: {
        Text("See what to move from savings to checking to cover these payments.")
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

extension CreditCardsView {
  /// Payments due before the next payday, then the rest, or every payment without a budget.
  @ViewBuilder
  fileprivate func payoffSections(_ schedule: CardPayoffSchedule) -> some View {
    if let payday = schedule.nextPayday {
      let paydayText = payday.formatted(.dateTime.month(.abbreviated).day())
      let totalText = Money.format(cents: schedule.dueBeforePaydayCents)
      Section {
        if schedule.beforePayday.isEmpty {
          Text("Nothing is due before payday.")
            .foregroundStyle(.secondary)
        }
        ForEach(schedule.beforePayday) { payment in
          CardPaymentRow(payment: payment)
        }
      } header: {
        Text("Due Before Payday")
      } footer: {
        Text("\(totalText) is due before payday on \(paydayText).")
      }
      if !schedule.afterPayday.isEmpty {
        Section("Later") {
          ForEach(schedule.afterPayday) { payment in
            CardPaymentRow(payment: payment)
          }
        }
      }
    } else if !schedule.payments.isEmpty {
      Section {
        ForEach(schedule.payments) { payment in
          CardPaymentRow(payment: payment)
        }
      } header: {
        Text("Upcoming Payments")
      } footer: {
        Text("Set up a budget to see what's due before payday.")
      }
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

/// A payment's card, amount, due date, the cash needed by then, and any autopay warning.
private struct CardPaymentRow: View {
  let payment: ScheduledCardPayment

  var body: some View {
    let dueText = payment.dueDate.formatted(.dateTime.month(.abbreviated).day())
    let cashText = Money.format(cents: payment.cashNeededCents)
    VStack(alignment: .leading, spacing: 4) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline) {
          name
          Spacer(minLength: 12)
          amount
        }
        VStack(alignment: .leading, spacing: 4) {
          name
          amount
        }
      }
      Text("Due \(dueText), \(CreditCardRow.text(daysLeft: payment.daysLeft))")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Text("Cash needed by \(dueText): \(cashText)")
        .font(.subheadline)
      if payment.needsAutopayAttention {
        Label(
          Self.autopayWarning(daysLeft: payment.daysLeft),
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.caption)
        .foregroundStyle(.orange)
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  private var name: some View {
    Text(payment.name)
      .font(.headline)
  }

  private var amount: some View {
    AmountText(cents: payment.amountCents, accessibilityTitle: "Amount due")
  }

  static func autopayWarning(daysLeft: Int) -> String {
    switch daysLeft {
    case 0: "No autopay — due today"
    case 1: "No autopay — due tomorrow"
    default: "No autopay — due in \(daysLeft) days"
    }
  }
}

/// A card's spend this month, with last month's for comparison.
private struct CardSpendRow: View {
  let spend: CardMonthlySpend

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline) {
          name
          Spacer(minLength: 12)
          amount
        }
        VStack(alignment: .leading, spacing: 4) {
          name
          amount
        }
      }
      Text("Last month: \(Money.format(cents: spend.lastMonthCents))")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  private var name: some View {
    Text(spend.name)
      .font(.headline)
  }

  private var amount: some View {
    AmountText(cents: spend.thisMonthCents, accessibilityTitle: "This month")
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
