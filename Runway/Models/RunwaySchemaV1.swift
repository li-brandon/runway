import Foundation
import SwiftData

/// The first shipped SwiftData schema. All money values are stored as integer cents (USD).
enum RunwaySchemaV1: VersionedSchema {
  static var versionIdentifier: Schema.Version {
    Schema.Version(1, 0, 0)
  }

  static var models: [any PersistentModel.Type] {
    [Budget.self, FixedBill.self, Expense.self, Category.self]
  }
}

typealias Budget = RunwaySchemaV1.Budget
typealias FixedBill = RunwaySchemaV1.FixedBill
typealias Expense = RunwaySchemaV1.Expense
typealias Category = RunwaySchemaV1.Category

/// How long one budgeting period lasts.
enum PeriodLength: String, Codable, CaseIterable, Sendable {
  case weekly
  case biweekly
  case monthly
}

extension RunwaySchemaV1 {
  @Model
  final class Budget {
    var periodLength: PeriodLength = PeriodLength.biweekly
    var periodStart: Date = Date.now
    var spendablePerPeriodCents: Int = 0
    var incomeCents: Int?
    var savingsCents: Int = 0
    var carryoverEnabled: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \FixedBill.budget)
    var fixedBills: [FixedBill] = []

    init(
      periodLength: PeriodLength = .biweekly,
      periodStart: Date,
      spendablePerPeriodCents: Int,
      incomeCents: Int? = nil,
      savingsCents: Int = 0,
      carryoverEnabled: Bool = false
    ) {
      self.periodLength = periodLength
      self.periodStart = periodStart
      self.spendablePerPeriodCents = spendablePerPeriodCents
      self.incomeCents = incomeCents
      self.savingsCents = savingsCents
      self.carryoverEnabled = carryoverEnabled
    }
  }

  @Model
  final class FixedBill {
    var name: String = ""
    var amountCents: Int = 0
    /// Day of the month the bill is due (1–31), if known.
    var dueDay: Int?
    var budget: Budget?

    init(name: String, amountCents: Int, dueDay: Int? = nil) {
      self.name = name
      self.amountCents = amountCents
      self.dueDay = dueDay
    }
  }

  @Model
  final class Expense {
    var amountCents: Int = 0
    var note: String = ""
    var date: Date = Date.now

    @Relationship(deleteRule: .nullify)
    var category: Category?

    init(amountCents: Int, note: String = "", date: Date = .now) {
      self.amountCents = amountCents
      self.note = note
      self.date = date
    }
  }

  @Model
  final class Category {
    var name: String = ""
    /// SF Symbol name.
    var symbol: String = "tag"
    /// `#RRGGBB` hex string.
    var colorHex: String = "#8E8E93"
    var sortOrder: Int = 0

    @Relationship(deleteRule: .nullify, inverse: \Expense.category)
    var expenses: [Expense] = []

    init(name: String, symbol: String, colorHex: String, sortOrder: Int = 0) {
      self.name = name
      self.symbol = symbol
      self.colorHex = colorHex
      self.sortOrder = sortOrder
    }
  }
}
