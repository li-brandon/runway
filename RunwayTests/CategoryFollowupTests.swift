import Foundation
import SwiftData
import Testing

@testable import Runway

struct CategoryFollowupTests {
  @Test("Deletion confirmation uses singular only for one expense")
  func pluralization() {
    for count in [0, 1, 2] {
      let noun = count == 1 ? "expense" : "expenses"
      let message = CategoryService.deletionMessage(name: "Food", expenseCount: count)
      #expect(message == "Delete Food? \(count) \(noun) will move to Other.")
    }
  }

  @Test("Create and delete preserve customized defaults without running seed repair")
  func noReseed() throws {
    let container = try RunwayModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    let service = CategoryService(context: context)
    try service.seed()
    let categories: [RunwaySchemaV1.Category] = try service.categories()
    let food = try #require(categories.first { $0.name == "Food" })
    let bills = try #require(categories.first { $0.name == "Bills" })
    let shopping = try #require(categories.first { $0.name == "Shopping" })
    try service.update(food, name: "Dining", symbol: "heart", colorHex: "#007AFF")
    try service.delete(bills)
    try context.save()
    // A legacy uncategorized row proves seed's full repair pass did not run.
    let legacy = Expense(amountCents: 50)
    context.insert(legacy)
    try service.createExpense(amountCents: 100)
    #expect(legacy.category == nil)
    let assigned = try service.createExpense(amountCents: 200, category: shopping)
    try service.delete(shopping)
    try context.save()
    #expect(legacy.category == nil)
    #expect(assigned.category?.isSystem == true)
    let loaded = ModelContext(container)
    let saved = try CategoryService(context: loaded).categories()
    #expect(!saved.contains { $0.name == "Bills" || $0.name == "Shopping" || $0.name == "Food" })
    let dining = try #require(saved.first { $0.name == "Dining" })
    #expect(dining.symbol == "heart")
    #expect(dining.colorHex == "#007AFF")
    #expect(saved.count == 5)
  }

  @Test("A backdated expense logged last puts its category first")
  func backdatedOrdering() throws {
    let container = try RunwayModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    let service = CategoryService(context: context)
    try service.seed()
    let categories: [RunwaySchemaV1.Category] = try service.categories()
    let earlier = Date(timeIntervalSince1970: 100)
    let later = Date(timeIntervalSince1970: 200)
    try service.createExpense(
      amountCents: 100,
      date: later,
      category: categories[0],
      now: earlier
    )
    try service.createExpense(
      amountCents: 100,
      date: earlier,
      category: categories[1],
      now: later
    )
    try context.save()
    let loaded = ModelContext(container)
    let saved = try CategoryService(context: loaded).categories()
    let expenses = try loaded.fetch(FetchDescriptor<Expense>())
    let usage = expenses.compactMap { expense -> (id: PersistentIdentifier, date: Date)? in
      guard let category = expense.category else { return nil }
      return (id: category.persistentModelID, date: expense.createdAt)
    }
    let ordered = CategoryOrdering.orderedIDs(in: saved.map(\.persistentModelID), usage: usage)
    #expect(ordered.first == saved[1].persistentModelID)
  }
}
