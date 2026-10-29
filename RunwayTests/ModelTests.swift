import Foundation
import SwiftData
import Testing

@testable import Runway

struct ModelTests {
  let container: ModelContainer

  init() throws {
    container = try RunwayModelContainer.make(inMemory: true)
  }

  @Test("Budget inserts and fetches with its defaults")
  func budgetRoundTrip() throws {
    let context = ModelContext(container)
    let start = Date(timeIntervalSince1970: 1_767_225_600)
    let budget = Budget(
      periodStart: start,
      spendablePerPeriodCents: 50_000,
      incomeCents: 200_000,
      savingsCents: 10_000
    )
    context.insert(budget)
    try context.save()

    let budgets = try context.fetch(FetchDescriptor<Budget>())
    #expect(budgets.count == 1)
    let fetched = try #require(budgets.first)
    #expect(fetched.periodLength == .biweekly)
    #expect(fetched.periodStart == start)
    #expect(fetched.spendablePerPeriodCents == 50_000)
    #expect(fetched.incomeCents == 200_000)
    #expect(fetched.savingsCents == 10_000)
    #expect(fetched.carryoverEnabled)
    #expect(fetched.fixedBills.isEmpty)
    #expect(fetched.carryoverChanges.isEmpty)
  }

  @Test("Budget income is optional")
  func budgetWithoutIncome() throws {
    let context = ModelContext(container)
    context.insert(Budget(periodLength: .monthly, periodStart: .now, spendablePerPeriodCents: 1))
    try context.save()

    let fetched = try #require(try context.fetch(FetchDescriptor<Budget>()).first)
    #expect(fetched.incomeCents == nil)
    #expect(fetched.periodLength == .monthly)
  }

  @Test("PeriodLength raw values are stable")
  func periodLengthRawValues() {
    #expect(PeriodLength.allCases.map(\.rawValue) == ["weekly", "biweekly", "monthly"])
  }

  @Test("Fixed bills link to their budget in both directions")
  func budgetFixedBills() throws {
    let context = ModelContext(container)
    let budget = Budget(periodStart: .now, spendablePerPeriodCents: 40_000)
    context.insert(budget)
    let rent = FixedBill(name: "Rent", amountCents: 120_000, dueDay: 1)
    let phone = FixedBill(name: "Phone", amountCents: 4_500)
    context.insert(rent)
    context.insert(phone)
    budget.fixedBills.append(rent)
    budget.fixedBills.append(phone)
    try context.save()

    let bills = try context.fetch(FetchDescriptor<FixedBill>(sortBy: [SortDescriptor(\.name)]))
    #expect(bills.map(\.name) == ["Phone", "Rent"])
    #expect(bills.allSatisfy { $0.budget?.persistentModelID == budget.persistentModelID })
    #expect(bills.first?.dueDay == nil)
    #expect(bills.last?.dueDay == 1)
    #expect(budget.fixedBills.count == 2)
  }

  @Test("Deleting a budget deletes its fixed bills")
  func budgetDeleteCascades() throws {
    let context = ModelContext(container)
    let budget = Budget(periodStart: .now, spendablePerPeriodCents: 40_000)
    context.insert(budget)
    let bill = FixedBill(name: "Gym", amountCents: 3_000)
    context.insert(bill)
    bill.budget = budget
    try context.save()

    context.delete(budget)
    try context.save()

    #expect(try context.fetchCount(FetchDescriptor<Budget>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<FixedBill>()) == 0)
  }

  @Test("Expenses link to an optional category")
  func expenseCategory() throws {
    let context = ModelContext(container)
    let groceries = RunwaySchemaV1.Category(
      name: "Groceries",
      symbol: "cart",
      colorHex: "#34C759",
      sortOrder: 1
    )
    context.insert(groceries)
    let tagged = Expense(amountCents: 2_350, note: "Market")
    let untagged = Expense(amountCents: 499)
    context.insert(tagged)
    context.insert(untagged)
    tagged.category = groceries
    try context.save()

    let expenses = try context.fetch(
      FetchDescriptor<Expense>(sortBy: [SortDescriptor(\.amountCents)])
    )
    #expect(expenses.map(\.amountCents) == [499, 2_350])
    #expect(expenses.first?.category == nil)
    #expect(expenses.last?.category?.name == "Groceries")
    #expect(groceries.expenses.map(\.note) == ["Market"])
  }

  @Test("Deleting a category nullifies its expenses instead of deleting them")
  func categoryDeleteNullifies() throws {
    let context = ModelContext(container)
    let dining = RunwaySchemaV1.Category(
      name: "Dining",
      symbol: "fork.knife",
      colorHex: "#FF9500"
    )
    context.insert(dining)
    let lunch = Expense(amountCents: 1_200, note: "Lunch")
    let dinner = Expense(amountCents: 3_400, note: "Dinner")
    context.insert(lunch)
    context.insert(dinner)
    lunch.category = dining
    dinner.category = dining
    try context.save()
    #expect(dining.expenses.count == 2)

    context.delete(dining)
    try context.save()

    #expect(try context.fetchCount(FetchDescriptor<RunwaySchemaV1.Category>()) == 0)
    let expenses = try context.fetch(FetchDescriptor<Expense>())
    #expect(expenses.count == 2)
    #expect(expenses.allSatisfy { $0.category == nil })
  }
}
