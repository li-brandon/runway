import Foundation
import SwiftData
import Testing

@testable import Runway

/// Saving a `BudgetDraft` to SwiftData and loading it back, including across a relaunch.
struct BudgetSetupPersistenceTests {
  let locale = Money.fixedLocale
  let calendar = Calendar.gregorian("America/Chicago")

  /// Weekly from Friday 2026-06-05: 1,500 - (900 + 45.50) - 100 = 454.50 available.
  func makeDraft() -> BudgetDraft {
    var draft = BudgetDraft(periodStart: calendar.date(2026, 6, 5, 15, 30), locale: locale)
    draft.periodLength = .weekly
    draft.spendableText = "1,500"
    draft.incomeText = "1800"
    draft.savingsText = "100"
    draft.bills = [
      BudgetDraft.Bill(name: "Phone", amountText: "45.50"),
      BudgetDraft.Bill(name: " Rent ", amountText: "900", dueDay: 1),
    ]
    draft.carryoverEnabled = false
    return draft
  }

  /// The parts of a draft that should survive a save, without row or model identifiers.
  func summary(_ draft: BudgetDraft) -> [String] {
    let fields = [
      draft.periodLength.rawValue,
      "\(draft.periodStart.timeIntervalSince1970)",
      draft.spendableText,
      draft.incomeText,
      draft.savingsText,
      "carryover: \(draft.carryoverEnabled)",
    ]
    let bills = draft.bills.map { bill -> String in
      let dueDay = bill.dueDay.map { "\($0)" } ?? "-"
      return "\(bill.name) \(bill.amountText) \(dueDay)"
    }
    return fields + bills
  }

  /// `makeDraft()` after a save and load: the start is midnight, amounts are reformatted, the
  /// bill name is trimmed, and bills are ordered by due day.
  var savedSummary: [String] {
    [
      "weekly",
      "\(calendar.date(2026, 6, 5).timeIntervalSince1970)",
      "$1,500",
      "$1,800",
      "$100",
      "carryover: false",
      "Rent $900 1",
      "Phone $45.50 -",
    ]
  }

  @Test("A new budget saves the draft's values and loads back into the same draft")
  func insertAndLoad() throws {
    let container = try RunwayModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    let draft = makeDraft()
    let budget = try #require(draft.insertBudget(into: context, calendar: calendar))
    try context.save()

    #expect(budget.periodLength == .weekly)
    #expect(budget.periodStart == calendar.date(2026, 6, 5))
    #expect(budget.spendablePerPeriodCents == 150_000)
    #expect(budget.incomeCents == 180_000)
    #expect(budget.savingsCents == 10_000)
    #expect(!budget.carryoverEnabled)
    // A new budget has no history, so turning carryover off records no change.
    #expect(budget.carryoverChanges.isEmpty)
    #expect(try context.fetchCount(FetchDescriptor<FixedBill>()) == 2)

    // The engine spreads the available amount, not the raw spendable.
    #expect(budget.availablePerPeriodCents == 45_450)
    #expect(budget.availablePerPeriodCents == draft.availableCents)
    #expect(BudgetSnapshot(budget).spendablePerPeriodCents == 45_450)

    let loaded = BudgetDraft(budget: budget, locale: locale)
    #expect(summary(loaded) == savedSummary)
    #expect(loaded.availableCents == 45_450)
  }

  @Test("Loaded formatted amounts save with identical cents", arguments: [0, 7, 1_250, 240_000])
  func formattedAmountsRoundTrip(cents: Int) throws {
    let container = try RunwayModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    var original = makeDraft()
    original.spendableText = "\(cents / 100).\(String(format: "%02d", cents % 100))"
    original.incomeText = original.spendableText
    original.savingsText = original.spendableText
    original.bills = [BudgetDraft.Bill(name: "Bill", amountText: original.spendableText)]
    let budget = try #require(original.insertBudget(into: context, calendar: calendar))
    try context.save()

    let loaded = BudgetDraft(budget: budget, locale: locale)
    let formatted = BudgetDraft.text(fromCents: cents)
    #expect(loaded.spendableText == formatted)
    #expect(loaded.incomeText == formatted)
    #expect(loaded.savingsText == formatted)
    if cents == 0 {
      #expect(loaded.savingsText == "$0")
    }
    #expect(loaded.bills.first?.amountText == formatted)
    #expect(loaded.apply(to: budget, now: calendar.date(2026, 6, 5), calendar: calendar))
    try context.save()
    #expect(budget.spendablePerPeriodCents == cents)
    #expect(budget.incomeCents == cents)
    #expect(budget.savingsCents == cents)
    #expect(budget.fixedBills.first?.amountCents == cents)
  }

  @Test("Applying an edited draft updates, adds, and removes bills in place")
  func applyEdits() throws {
    let container = try RunwayModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    let budget = try #require(makeDraft().insertBudget(into: context, calendar: calendar))
    try context.save()
    let rentID = try #require(budget.fixedBills.first { $0.name == "Rent" }?.persistentModelID)

    var draft = BudgetDraft(budget: budget, locale: locale)
    draft.periodLength = .biweekly
    draft.spendableText = "3000"
    draft.incomeText = ""
    draft.savingsText = ""
    draft.bills.removeAll { $0.name == "Phone" }
    draft.bills[0].amountText = "950"
    draft.bills.append(BudgetDraft.Bill(name: "Gym", amountText: "30", dueDay: 20))
    draft.carryoverEnabled = true
    #expect(draft.apply(to: budget, now: calendar.date(2026, 6, 10, 12), calendar: calendar))
    try context.save()

    #expect(budget.periodLength == .biweekly)
    #expect(budget.spendablePerPeriodCents == 300_000)
    #expect(budget.incomeCents == nil)
    #expect(budget.savingsCents == 0)
    let bills = try context.fetch(FetchDescriptor<FixedBill>(sortBy: [SortDescriptor(\.name)]))
    #expect(bills.map(\.name) == ["Gym", "Rent"])
    #expect(bills.map(\.amountCents) == [3_000, 95_000])
    #expect(bills.last?.persistentModelID == rentID)
    #expect(budget.availablePerPeriodCents == 300_000 - 98_000)

    // An existing budget goes through `setCarryover`, so the change waits for the next period.
    #expect(budget.carryoverEnabled)
    #expect(
      BudgetSnapshot(budget).carryoverChanges == [
        CarryoverChangeSnapshot(
          enabled: true,
          previousEnabled: false,
          effectiveAt: calendar.date(2026, 6, 19)
        )
      ]
    )
  }

  @Test("A draft with issues saves nothing")
  func applyWithIssues() throws {
    let container = try RunwayModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    var draft = makeDraft()
    draft.spendableText = "-1"
    #expect(draft.insertBudget(into: context, calendar: calendar) == nil)
    #expect(try context.fetchCount(FetchDescriptor<Budget>()) == 0)

    let budget = try #require(makeDraft().insertBudget(into: context, calendar: calendar))
    try context.save()
    draft = BudgetDraft(budget: budget, locale: locale)
    draft.spendableText = "1"
    draft.bills[0].name = ""
    #expect(!draft.apply(to: budget, now: calendar.date(2026, 6, 10), calendar: calendar))
    #expect(budget.spendablePerPeriodCents == 150_000)
    #expect(budget.fixedBills.count == 2)
  }

  @Test("A saved budget survives a relaunch: a new container on the same store file")
  func survivesRelaunch() throws {
    let directoryName = "RunwayTests-\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appending(path: directoryName)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "Runway.store")
    let draft = makeDraft()

    try saveInFirstLaunch(draft, to: url)

    let container = try RunwayModelContainer.make(url: url)
    let context = ModelContext(container)
    let budgets = try context.fetch(FetchDescriptor<Budget>())
    #expect(budgets.count == 1)
    let budget = try #require(budgets.first)
    #expect(AppRoute(hasBudget: !budgets.isEmpty) == .main)
    let loaded = BudgetDraft(budget: budget, locale: locale)
    #expect(summary(loaded) == savedSummary)
    #expect(loaded.availableCents == draft.availableCents)
  }

  /// Saves `draft` with its own container, which is released on return.
  private func saveInFirstLaunch(_ draft: BudgetDraft, to url: URL) throws {
    let container = try RunwayModelContainer.make(url: url)
    let context = ModelContext(container)
    #expect(try context.fetchCount(FetchDescriptor<Budget>()) == 0)
    _ = try #require(draft.insertBudget(into: context, calendar: calendar))
    try context.save()
  }
}
