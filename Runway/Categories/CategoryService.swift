import Foundation
import SwiftData

/// Owns category mutations. Callers save the context once per operation and roll back on failure.
struct CategoryService {
  let context: ModelContext

  enum Issue: LocalizedError, Equatable {
    case emptyName
    case duplicateName
    case protectedCategory
    case invalidAppearance

    var errorDescription: String? {
      switch self {
      case .emptyName: "Enter a category name."
      case .duplicateName: "A category with that name already exists."
      case .protectedCategory: "Other cannot be renamed or deleted."
      case .invalidAppearance: "Choose a color and symbol from the available options."
      }
    }
  }

  static let colors = [
    "#FF9500", "#34C759", "#007AFF", "#AF52DE", "#FF2D55", "#00C7BE", "#8E8E93",
  ]
  static let symbols = [
    "fork.knife", "cart", "car", "bag", "film", "doc.text", "tag", "heart", "house", "airplane",
  ]
  static let defaultNames = [
    "Food", "Groceries", "Transport", "Shopping", "Entertainment", "Bills", "Other",
  ]

  func categories() throws -> [Category] {
    try context.fetch(
      FetchDescriptor<Category>(sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.name)])
    )
  }

  /// Other is also the durable seed marker. Renaming or deleting a default never restores it.
  /// Existing pre-feature categories are retained; matching default names are adopted.
  @discardableResult
  func seed() throws -> Category {
    var existing = try categories()
    let other: Category
    if let system = existing.first(where: { $0.isSystem }) {
      other = system
    } else {
      for (index, name) in Self.defaultNames.enumerated() {
        if let match = existing.first(where: { Self.nameKey($0.name) == Self.nameKey(name) }) {
          if name == "Other" {
            match.name = "Other"
            match.isSystem = true
          }
        } else {
          let category = Category(
            name: name,
            symbol: Self.symbols[index],
            colorHex: Self.colors[index],
            sortOrder: (existing.map(\.sortOrder).max() ?? -1) + 1,
            isSystem: name == "Other"
          )
          context.insert(category)
          existing.append(category)
        }
      }
      other = existing.first(where: { $0.isSystem })!
    }
    // The relationship stays optional for SwiftData. Repair any old uncategorized expenses.
    for expense in try context.fetch(FetchDescriptor<Expense>()) where expense.category == nil {
      expense.category = other
    }
    return other
  }

  @discardableResult
  func add(name: String, symbol: String, colorHex: String) throws -> Category {
    let name = try validatedName(name)
    try validateAppearance(symbol: symbol, colorHex: colorHex)
    let category = Category(
      name: name,
      symbol: symbol,
      colorHex: colorHex,
      sortOrder: (try categories().map(\.sortOrder).max() ?? -1) + 1
    )
    context.insert(category)
    return category
  }

  /// Validates all fields before changing any of them.
  func update(_ category: Category, name: String, symbol: String, colorHex: String) throws {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !category.isSystem || name == category.name else { throw Issue.protectedCategory }
    let validated = try validatedName(name, excluding: category)
    try validateAppearance(symbol: symbol, colorHex: colorHex)
    category.name = validated
    category.symbol = symbol
    category.colorHex = colorHex
  }

  /// SwiftUI's move offsets refer to the complete list sorted by sortOrder.
  func move(from offsets: IndexSet, to destination: Int) throws {
    var ordered = try categories()
    let moved = offsets.sorted().map { ordered[$0] }
    let insertion = destination - offsets.filter { $0 < destination }.count
    for index in offsets.sorted(by: >) {
      ordered.remove(at: index)
    }
    ordered.insert(contentsOf: moved, at: insertion)
    for (index, category) in ordered.enumerated() {
      category.sortOrder = index
    }
  }

  func delete(_ category: Category) throws {
    guard !category.isSystem else { throw Issue.protectedCategory }
    let other = try otherCategory()
    // Copy before changing inverse relationships, then reassign before deleting.
    let expenses = Array(category.expenses)
    for expense in expenses {
      expense.category = other
    }
    context.delete(category)
  }

  /// All app expense creation goes through this method, including screenshot fixtures.
  @discardableResult
  func createExpense(
    amountCents: Int,
    note: String = "",
    date: Date = .now,
    category: Category? = nil,
    now: Date = .now
  ) throws -> Expense {
    let assigned = try category ?? otherCategory()
    let expense = Expense(amountCents: amountCents, note: note, date: date, createdAt: now)
    context.insert(expense)
    expense.category = assigned
    return expense
  }

  /// Fetch the seed marker directly; normal mutations never scan or repair all expenses.
  private func otherCategory() throws -> Category {
    var descriptor = FetchDescriptor<Category>(predicate: #Predicate { $0.isSystem })
    descriptor.fetchLimit = 1
    if let other = try context.fetch(descriptor).first { return other }
    return try seed()
  }

  static func deletionMessage(name: String, expenseCount: Int) -> String {
    let noun = expenseCount == 1 ? "expense" : "expenses"
    return "Delete \(name)? \(expenseCount) \(noun) will move to Other."
  }

  private func validatedName(_ name: String, excluding category: Category? = nil) throws -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw Issue.emptyName }
    let duplicate = try categories().contains {
      $0 !== category && Self.nameKey($0.name) == Self.nameKey(trimmed)
    }
    guard !duplicate else { throw Issue.duplicateName }
    return trimmed
  }

  private func validateAppearance(symbol: String, colorHex: String) throws {
    guard Self.symbols.contains(symbol), Self.colors.contains(colorHex) else {
      throw Issue.invalidAppearance
    }
  }

  private static func nameKey(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
  }
}
