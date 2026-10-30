import Foundation
import SwiftData

/// Current schema (1.1.0). New attributes have defaults and new relationships start empty.
/// The original 1.0.0 shape is frozen in `RunwaySchemaV1Original` for lightweight migration.
enum RunwaySchemaV1: VersionedSchema {
  static var versionIdentifier: Schema.Version {
    Schema.Version(1, 1, 0)
  }

  static var models: [any PersistentModel.Type] {
    [
      Budget.self, FixedBill.self, Expense.self, Category.self, CarryoverChange.self,
      AmountChange.self, ScheduleChange.self, ExtraMoney.self, BillPayment.self,
    ]
  }
}

typealias Budget = RunwaySchemaV1.Budget
typealias FixedBill = RunwaySchemaV1.FixedBill
typealias Expense = RunwaySchemaV1.Expense
typealias Category = RunwaySchemaV1.Category
typealias CarryoverChange = RunwaySchemaV1.CarryoverChange
typealias AmountChange = RunwaySchemaV1.AmountChange
typealias ScheduleChange = RunwaySchemaV1.ScheduleChange
typealias ExtraMoney = RunwaySchemaV1.ExtraMoney
typealias BillPayment = RunwaySchemaV1.BillPayment

/// How long one budgeting period lasts.
enum PeriodLength: String, Codable, CaseIterable, Sendable {
  case weekly
  case biweekly
  case monthly
}

#if DEBUG
  enum ExpenseCreationGuard {
    @TaskLocal static var isAuthorized = false
  }
#endif

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
    /// The time zone whose local midnights the day-only dates (`periodStart` and every change's
    /// `effectiveAt`) are stored in. Empty until first set; see `adoptTimeZone(of:)`.
    var timeZoneIdentifier: String = ""

    @Relationship(deleteRule: .cascade, inverse: \FixedBill.budget)
    var fixedBills: [FixedBill] = []

    /// Every change to `carryoverEnabled`, in no particular order.
    @Relationship(deleteRule: .cascade, inverse: \CarryoverChange.budget)
    var carryoverChanges: [CarryoverChange] = []

    /// Every mid-period change to the available amount, in no particular order. Record them
    /// with `recordAmountChange(from:now:calendar:)`.
    @Relationship(deleteRule: .cascade, inverse: \AmountChange.budget)
    var amountChanges: [AmountChange] = []

    /// Every change to the period length or payday, in no particular order. Change the
    /// schedule with `updatePeriod(_:start:now:calendar:)`.
    @Relationship(deleteRule: .cascade, inverse: \ScheduleChange.budget)
    var scheduleChanges: [ScheduleChange] = []

    /// One-off money added to a period, in no particular order.
    @Relationship(deleteRule: .cascade, inverse: \ExtraMoney.budget)
    var extraMoney: [ExtraMoney] = []

    /// Every bill mark (paid, skipped, or unpaid again), in no particular order.
    @Relationship(deleteRule: .cascade, inverse: \BillPayment.budget)
    var billPayments: [BillPayment] = []

    init(
      periodLength: PeriodLength = .biweekly,
      periodStart: Date,
      spendablePerPeriodCents: Int,
      incomeCents: Int? = nil,
      savingsCents: Int = 0,
      carryoverEnabled: Bool = true,
      timeZoneIdentifier: String = ""
    ) {
      self.periodLength = periodLength
      self.periodStart = periodStart
      self.spendablePerPeriodCents = spendablePerPeriodCents
      self.incomeCents = incomeCents
      self.savingsCents = savingsCents
      self.carryoverEnabled = carryoverEnabled
      self.timeZoneIdentifier = timeZoneIdentifier
    }
  }

  @Model
  final class FixedBill {
    var name: String = ""
    var amountCents: Int = 0
    /// Day of the month the bill is due (1–31), if known.
    var dueDay: Int?
    var budget: Budget?

    /// Paid or skipped marks. They outlive the bill so past periods keep their figures.
    @Relationship(deleteRule: .nullify, inverse: \BillPayment.bill)
    var payments: [BillPayment] = []

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
    /// When the expense was logged, independent of its spending date.
    var createdAt: Date = Date.now

    /// Optional for SwiftData; app creation uses CategoryService to always assign a category.
    @Relationship(deleteRule: .nullify)
    var category: Category?

    #if DEBUG
      @Transient var creationWasAuthorized: Bool = false
    #endif

    init(amountCents: Int, note: String = "", date: Date = .now, createdAt: Date = .now) {
      #if DEBUG
        creationWasAuthorized = ExpenseCreationGuard.isAuthorized
        assert(creationWasAuthorized, "Create expenses through CategoryService.createExpense")
      #endif
      self.amountCents = amountCents
      self.note = note
      self.date = date
      self.createdAt = createdAt
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

  /// A change to the budget's available amount (spendable − bills − savings). Days before
  /// `effectiveAt` (a local midnight) used `previousAvailableCents`; the next change, or the
  /// budget's live amounts, apply from `effectiveAt` on.
  @Model
  final class AmountChange {
    var previousAvailableCents: Int = 0
    var effectiveAt: Date = Date.now
    var budget: Budget?

    init(previousAvailableCents: Int, effectiveAt: Date) {
      self.previousAvailableCents = previousAvailableCents
      self.effectiveAt = effectiveAt
    }
  }

  /// A change to the period length or payday. Days before `effectiveAt` (a local midnight)
  /// followed the previous schedule, and the period running then ended at `effectiveAt`.
  @Model
  final class ScheduleChange {
    var previousPeriodLength: PeriodLength = PeriodLength.biweekly
    var previousPeriodStart: Date = Date.now
    var effectiveAt: Date = Date.now
    var budget: Budget?

    init(previousPeriodLength: PeriodLength, previousPeriodStart: Date, effectiveAt: Date) {
      self.previousPeriodLength = previousPeriodLength
      self.previousPeriodStart = previousPeriodStart
      self.effectiveAt = effectiveAt
    }
  }

  /// One-off money, like a bonus or gift, added to the period containing `date`.
  @Model
  final class ExtraMoney {
    var amountCents: Int = 0
    var note: String = ""
    var date: Date = Date.now
    var budget: Budget?

    init(amountCents: Int, note: String = "", date: Date) {
      self.amountCents = amountCents
      self.note = note
      self.date = date
    }
  }

  /// A bill marked paid, skipped, or unpaid again in the period containing `date`. Marks are
  /// only ever added, so earlier days keep their figures: the bill's status is its latest mark in
  /// the period (by `sequence`), and each mark records in `adjustmentCents` how much the period's
  /// money changes from `date` on.
  ///
  /// While paid or skipped, the period gets back `plannedCents - paidCents`: the whole bill when
  /// skipped, the difference when paid at another amount, and nothing when paid as planned.
  @Model
  final class BillPayment {
    var isSkipped: Bool = false
    /// Clears the bill's earlier mark in the period: it's unpaid again.
    var isCleared: Bool = false
    /// The bill's amount set aside for the period when it was marked.
    var plannedCents: Int = 0
    /// What was paid; 0 when skipped or cleared.
    var paidCents: Int = 0
    /// The change, from `date` on, to what the period gets back from the bill.
    var adjustmentCents: Int = 0
    /// Orders marks made at the same moment. Higher is later.
    var sequence: Int = 0
    var date: Date = Date.now
    var budget: Budget?
    var bill: FixedBill?

    init(
      isSkipped: Bool,
      isCleared: Bool = false,
      plannedCents: Int,
      paidCents: Int,
      adjustmentCents: Int,
      sequence: Int,
      date: Date
    ) {
      self.isSkipped = isSkipped
      self.isCleared = isCleared
      self.plannedCents = plannedCents
      self.paidCents = paidCents
      self.adjustmentCents = adjustmentCents
      self.sequence = sequence
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
