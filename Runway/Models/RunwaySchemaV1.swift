import Foundation
import SwiftData

/// The first SwiftData schema. All money values are stored as integer cents (USD).
///
/// V1 hasn't shipped yet, so until the first release it may still be edited in place.
enum RunwaySchemaV1: VersionedSchema {
  static var versionIdentifier: Schema.Version {
    Schema.Version(1, 0, 0)
  }

  static var models: [any PersistentModel.Type] {
    [Budget.self, FixedBill.self, Expense.self, Category.self, CarryoverChange.self]
  }
}

typealias Budget = RunwaySchemaV1.Budget
typealias FixedBill = RunwaySchemaV1.FixedBill
typealias Expense = RunwaySchemaV1.Expense
typealias Category = RunwaySchemaV1.Category
typealias CarryoverChange = RunwaySchemaV1.CarryoverChange

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
    /// The current carryover setting. Change it with `setCarryover(_:now:calendar:)` so the change
    /// is recorded in `carryoverChanges` and only applies from the next period.
    var carryoverEnabled: Bool = true

    @Relationship(deleteRule: .cascade, inverse: \FixedBill.budget)
    var fixedBills: [FixedBill] = []

    /// Every change to `carryoverEnabled`, in no particular order.
    @Relationship(deleteRule: .cascade, inverse: \CarryoverChange.budget)
    var carryoverChanges: [CarryoverChange] = []

    init(
      periodLength: PeriodLength = .biweekly,
      periodStart: Date,
      spendablePerPeriodCents: Int,
      incomeCents: Int? = nil,
      savingsCents: Int = 0,
      carryoverEnabled: Bool = true
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

    /// Optional for SwiftData; app creation uses CategoryService to always assign a category.
    @Relationship(deleteRule: .nullify)
    var category: Category?

    init(amountCents: Int, note: String = "", date: Date = .now) {
      self.amountCents = amountCents
      self.note = note
      self.date = date
    }
  }

  /// A change to `Budget.carryoverEnabled`. It applies from the period boundary `effectiveAt`.
  @Model
  final class CarryoverChange {
    var enabled: Bool = true
    /// The setting in effect before this change, so the engine never has to assume it.
    var previousEnabled: Bool = false
    var effectiveAt: Date = Date.now
    var budget: Budget?

    init(enabled: Bool, previousEnabled: Bool, effectiveAt: Date) {
      self.enabled = enabled
      self.previousEnabled = previousEnabled
      self.effectiveAt = effectiveAt
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
    /// Only Other is a system category. Also records that defaults have already been seeded.
    var isSystem: Bool = false

    @Relationship(deleteRule: .nullify, inverse: \Expense.category)
    var expenses: [Expense] = []

    init(
      name: String,
      symbol: String,
      colorHex: String,
      sortOrder: Int = 0,
      isSystem: Bool = false
    ) {
      self.name = name
      self.symbol = symbol
      self.colorHex = colorHex
      self.sortOrder = sortOrder
      self.isSystem = isSystem
    }
  }
}
