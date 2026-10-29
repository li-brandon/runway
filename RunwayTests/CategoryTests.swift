import Foundation
import SwiftData
import Testing

@testable import Runway

struct CategoryTests {
  let container: ModelContainer

  init() throws {
    container = try RunwayModelContainer.make(inMemory: true)
  }

  @Test("Defaults seed once and retain their identities across contexts")
  func seedIdempotently() throws {
    let context = ModelContext(container)
    let service = CategoryService(context: context)
    let other = try service.seed()
    try context.save()
    let initial = try service.categories()
    #expect(initial.map(\.name) == CategoryService.defaultNames)
    #expect(initial.map(\.sortOrder) == Array(0..<7))
    #expect(initial.map(\.symbol) == Array(CategoryService.symbols.prefix(7)))
    #expect(initial.map(\.colorHex) == CategoryService.colors)
    #expect(initial.filter(\.isSystem).map(\.name) == ["Other"])
    #expect(other.isSystem)
    let ids = initial.map(\.persistentModelID)

    let relaunched = ModelContext(container)
    let again = CategoryService(context: relaunched)
    try again.seed()
    try again.seed()
    try relaunched.save()
    #expect(try again.categories().map(\.persistentModelID) == ids)
  }

  @Test("Add, rename, recolor, symbol changes, and moves persist")
  func editAndMove() throws {
    let context = ModelContext(container)
    let service = CategoryService(context: context)
    try service.seed()
    let added = try service.add(name: "  Travel \n", symbol: "airplane", colorHex: "#007AFF")
    #expect(added.name == "Travel")
    #expect(added.sortOrder == 7)
    try service.update(added, name: " Holidays ", symbol: "heart", colorHex: "#FF2D55")
    // Move two separated rows down, preserving their relative order.
    try service.move(from: IndexSet([0, 2]), to: 8)
    #expect(
      try service.categories().map(\.name) == [
        "Groceries", "Shopping", "Entertainment", "Bills", "Other", "Holidays", "Food", "Transport",
      ]
    )
    try service.move(from: IndexSet(integer: 5), to: 0)
    try context.save()

    let loaded = try CategoryService(context: ModelContext(container)).categories()
    #expect(loaded.map(\.sortOrder) == Array(0..<8))
    #expect(loaded.first?.name == "Holidays")
    #expect(loaded.first?.symbol == "heart")
    #expect(loaded.first?.colorHex == "#FF2D55")
    #expect(loaded.first?.persistentModelID == added.persistentModelID)
  }

  @Test("Seeding preserves edits, moves, and deliberate deletion of default categories")
  func seedPreservesCustomization() throws {
    let context = ModelContext(container)
    let service = CategoryService(context: context)
    try service.seed()
    let categories = try service.categories()
    try service.update(categories[0], name: "Dining", symbol: "heart", colorHex: "#007AFF")
    try service.delete(categories[1])
    try service.move(from: IndexSet(integer: 0), to: 6)
    try context.save()
    let expected = try service.categories().map(\.name)

    let again = CategoryService(context: ModelContext(container))
    try again.seed()
    try again.context.save()
    #expect(try again.categories().map(\.name) == expected)
    #expect(try again.categories().count == 6)
    let dining = try #require(try again.categories().last)
    #expect(dining.name == "Dining")
    #expect(dining.symbol == "heart")
    #expect(dining.colorHex == "#007AFF")
  }

  @Test("Delete moves all expenses to Other without changing expense values or other categories")
  func deleteReassigns() throws {
    let context = ModelContext(container)
    let service = CategoryService(context: context)
    let other = try service.seed()
    let categories = try service.categories()
    let food = categories[0]
    let groceries = categories[1]
    let date = Date(timeIntervalSince1970: 1_000)
    try service.createExpense(amountCents: 100, note: "Lunch", date: date, category: food)
    try service.createExpense(amountCents: 200, note: "Dinner", date: date, category: food)
    try service.createExpense(amountCents: 300, category: groceries)
    try service.createExpense(amountCents: 400)
    try context.save()
    let otherID = other.persistentModelID
    #expect(food.expenses.count == 2)

    try service.delete(food)
    try context.save()
    let loaded = ModelContext(container)
    let expenses = try loaded.fetch(
      FetchDescriptor<Expense>(sortBy: [SortDescriptor(\.amountCents)])
    )
    #expect(expenses.map(\.amountCents) == [100, 200, 300, 400])
    #expect(expenses.prefix(2).map(\.note) == ["Lunch", "Dinner"])
    #expect(expenses.prefix(2).allSatisfy { $0.date == date })
    #expect(expenses.prefix(2).allSatisfy { $0.category?.persistentModelID == otherID })
    #expect(expenses[2].category?.name == "Groceries")
    #expect(expenses[3].category?.persistentModelID == otherID)
    #expect(expenses.allSatisfy { $0.category != nil })
    #expect(try CategoryService(context: loaded).categories().count == 6)
  }

  @Test("Other cannot be renamed or deleted but can be recolored and change symbol")
  func protectedOther() throws {
    let context = ModelContext(container)
    let service = CategoryService(context: context)
    let other = try service.seed()
    #expect(throws: CategoryService.Issue.protectedCategory) {
      try service.delete(other)
    }
    #expect(throws: CategoryService.Issue.protectedCategory) {
      try service.update(other, name: "Misc", symbol: "tag", colorHex: "#8E8E93")
    }
    try service.update(other, name: "Other", symbol: "heart", colorHex: "#AF52DE")
    try context.save()
    let loaded = try CategoryService(context: ModelContext(container)).seed()
    #expect(loaded.name == "Other")
    #expect(loaded.isSystem)
    #expect(loaded.symbol == "heart")
    #expect(loaded.colorHex == "#AF52DE")
  }

  @Test("Expense creation on a fresh store defaults to Other and respects explicit categories")
  func expenseDefault() throws {
    let context = ModelContext(container)
    let service = CategoryService(context: context)
    let expense = try service.createExpense(amountCents: 125, note: "Coffee")
    #expect(expense.category?.name == "Other")
    #expect(expense.category?.isSystem == true)
    let food = try #require(try service.categories().first)
    try service.createExpense(amountCents: 250, category: food)
    try context.save()
    let loaded = ModelContext(container)
    let expenses = try loaded.fetch(
      FetchDescriptor<Expense>(sortBy: [SortDescriptor(\.amountCents)])
    )
    #expect(expenses.map { $0.category?.name } == ["Other", "Food"])
    #expect(expenses.first?.note == "Coffee")
    #expect(try loaded.fetchCount(FetchDescriptor<RunwaySchemaV1.Category>()) == 7)
  }

  @Test("Seeding adopts existing defaults and repairs uncategorized expenses")
  func adoptsAndRepairs() throws {
    let context = ModelContext(container)
    let existing = RunwaySchemaV1.Category(name: " groceries ", symbol: "cart", colorHex: "#34C759")
    context.insert(existing)
    // Raw model insertion simulates data from before this feature.
    context.insert(makeFixtureExpense(amountCents: 125))
    let service = CategoryService(context: context)
    let other = try service.seed()
    try context.save()
    #expect(try service.categories().count == 7)
    let expense = try #require(try context.fetch(FetchDescriptor<Expense>()).first)
    #expect(expense.category?.persistentModelID == other.persistentModelID)
    #expect(existing.name == " groceries ")
  }

  @Test("Empty and duplicate names are rejected without changing existing data")
  func validation() throws {
    let context = ModelContext(container)
    let service = CategoryService(context: context)
    try service.seed()
    let food = try #require(try service.categories().first)
    for name in ["", " \n "] {
      #expect(throws: CategoryService.Issue.emptyName) {
        try service.add(name: name, symbol: "tag", colorHex: "#8E8E93")
      }
      #expect(throws: CategoryService.Issue.emptyName) {
        try service.update(food, name: name, symbol: "tag", colorHex: "#8E8E93")
      }
    }
    for name in ["groceries", " GROCERIES ", "GrOcErIeS"] {
      #expect(throws: CategoryService.Issue.duplicateName) {
        try service.add(name: name, symbol: "tag", colorHex: "#8E8E93")
      }
      #expect(throws: CategoryService.Issue.duplicateName) {
        try service.update(food, name: name, symbol: "tag", colorHex: "#8E8E93")
      }
    }
    #expect(food.name == "Food")
    #expect(food.symbol == "fork.knife")
    #expect(food.colorHex == "#FF9500")
    #expect(try service.categories().count == 7)
    // A category's own name is allowed, including a change of case.
    try service.update(food, name: "FOOD", symbol: "tag", colorHex: "#8E8E93")
    #expect(food.name == "FOOD")
    #expect(throws: CategoryService.Issue.invalidAppearance) {
      try service.update(food, name: "Dining", symbol: "not-a-symbol", colorHex: "#8E8E93")
    }
    #expect(throws: CategoryService.Issue.invalidAppearance) {
      try service.add(name: "Travel", symbol: "tag", colorHex: "invalid")
    }
    #expect(food.name == "FOOD")
    #expect(try service.categories().count == 7)
  }

  @Test("Logging times drive distinct recent categories followed by sortOrder")
  func recentOrdering() throws {
    let context = ModelContext(container)
    let service = CategoryService(context: context)
    try service.seed()
    let categories = try service.categories()
    for (index, categoryIndex) in [1, 3, 2, 3, 4].enumerated() {
      try service.createExpense(
        amountCents: 100,
        date: Date(timeIntervalSince1970: Double(index)),
        category: categories[categoryIndex],
        now: Date(timeIntervalSince1970: Double(index))
      )
    }
    try context.save()
    let loaded = ModelContext(container)
    let saved = try CategoryService(context: loaded).categories()
    let expenses = try loaded.fetch(FetchDescriptor<Expense>())
    let usage = expenses.compactMap { expense -> (id: PersistentIdentifier, date: Date)? in
      guard let category = expense.category else { return nil }
      return (id: category.persistentModelID, date: expense.createdAt)
    }
    let ordered = CategoryOrdering.orderedIDs(in: saved.map(\.persistentModelID), usage: usage)
    let names = ordered.compactMap { id in saved.first { $0.persistentModelID == id }?.name }
    #expect(
      names == ["Entertainment", "Shopping", "Transport", "Food", "Groceries", "Bills", "Other"]
    )
  }

  @Test("Ordering handles no usage, ties, unknown IDs, and different recent limits")
  func orderingEdges() {
    let ids = ["Food", "Groceries", "Transport", "Other"]
    let date = Date(timeIntervalSince1970: 1)
    let usage = [(id: "Transport", date: date), (id: "Food", date: date), (id: "Gone", date: date)]
    #expect(CategoryOrdering.orderedIDs(in: ids, usage: []) == ids)
    let expected = ["Food", "Transport", "Groceries", "Other"]
    #expect(CategoryOrdering.orderedIDs(in: ids, usage: usage) == expected)
    #expect(CategoryOrdering.orderedIDs(in: ids, usage: usage, recentLimit: 1) == ids)
    #expect(CategoryOrdering.orderedIDs(in: ids, usage: usage, recentLimit: 0) == ids)
    #expect(CategoryOrdering.orderedIDs(in: ids, usage: usage, recentLimit: -1) == ids)
    #expect(CategoryOrdering.orderedIDs(in: [String](), usage: usage).isEmpty)
  }
}
