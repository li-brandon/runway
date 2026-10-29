import Foundation
import SwiftData

/// Launch arguments used by CI to take screenshots.
///
/// - `-RunwayInMemoryStore` uses a fresh in-memory store instead of the on-disk one.
/// - `-RunwayScreenshotScenario <name>` seeds the store and opens a sample screen (see
///   `ScreenshotScenario`). It's ignored without `-RunwayInMemoryStore`, so sample data can never
///   be written to the real store.
/// - `-RunwayScreenshotScrollTo spendable` scrolls setup to its amount fields. It is also ignored
///   without `-RunwayInMemoryStore`.
struct LaunchOptions: Equatable, Sendable {
  static let inMemoryStoreArgument = "-RunwayInMemoryStore"
  static let screenshotScenarioArgument = "-RunwayScreenshotScenario"
  static let screenshotScrollToArgument = "-RunwayScreenshotScrollTo"

  var usesInMemoryStore = false
  var screenshotScenario: ScreenshotScenario?
  var screenshotScrollTo: String?

  init(arguments: [String]) {
    usesInMemoryStore = arguments.contains(Self.inMemoryStoreArgument)
    guard usesInMemoryStore else { return }
    if let index = arguments.firstIndex(of: Self.screenshotScenarioArgument),
      index + 1 < arguments.count
    {
      screenshotScenario = ScreenshotScenario(rawValue: arguments[index + 1])
    }
    if let index = arguments.firstIndex(of: Self.screenshotScrollToArgument),
      index + 1 < arguments.count,
      arguments[index + 1] == "spendable"
    {
      screenshotScrollTo = arguments[index + 1]
    }
  }
}

/// Sample states for CI screenshots.
enum ScreenshotScenario: String, CaseIterable, Sendable {
  /// First launch: no budget, so setup shows its defaults.
  case setupEmpty = "setup-empty"
  /// A filled-in budget with money left to spend, reopened from Settings.
  case setupFilled = "setup-filled"
  /// A budget whose bills and savings exceed spendable, reopened from Settings.
  case setupWarning = "setup-warning"

  case categories
  case categoryPicker = "category-picker"
  case quickLogEmpty = "quick-log-empty"
  case quickLogFilled = "quick-log-filled"
  case quickLogNote = "quick-log-note"
  case todayUndo = "today-undo"

  case todayNormal = "today-normal"
  case todayNear = "today-near"
  case todayOver = "today-over"
  case todayZero = "today-zero"
  case todayNoBudget = "today-no-budget"

  var todayDate: Date? {
    switch self {
    case .todayNormal, .todayNear, .todayOver, .todayZero, .todayNoBudget:
      Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 12))
    default:
      nil
    }
  }

  /// Inserts and saves sample data. A sample budget starts three days before `now`.
  @discardableResult
  func seed(into context: ModelContext, now: Date, calendar: Calendar) throws -> Budget? {
    let today = calendar.startOfDay(for: now)
    let periodStart = calendar.date(byAdding: .day, value: -3, to: today) ?? today
    let budget: Budget
    let bills: [FixedBill]
    switch self {
    case .setupEmpty, .todayNoBudget:
      return nil
    case .categories, .categoryPicker:
      let service = CategoryService(context: context)
      try service.seed()
      if self == .categoryPicker {
        let categories = try service.categories()
        for (index, name) in ["Shopping", "Transport", "Groceries", "Shopping"].enumerated() {
          let category = categories.first { $0.name == name }!
          try service.createExpense(
            amountCents: 1_200 + index * 100,
            date: now.addingTimeInterval(Double(index - 4) * 3_600),
            category: category,
            now: now.addingTimeInterval(Double(index - 4) * 3_600)
          )
        }
      }
      try context.save()
      return nil
    case .setupFilled, .quickLogEmpty, .quickLogFilled, .quickLogNote, .todayUndo:
      // 2,400 - (1,100 + 45 + 60) - 200 = 995 available.
      budget = Budget(
        periodStart: periodStart,
        spendablePerPeriodCents: 240_000,
        incomeCents: 285_000,
        savingsCents: 20_000
      )
      bills = [
        FixedBill(name: "Rent", amountCents: 110_000, dueDay: 1),
        FixedBill(name: "Phone", amountCents: 4_500, dueDay: 12),
        FixedBill(name: "Internet", amountCents: 6_000, dueDay: 18),
      ]
    case .todayNormal, .todayNear, .todayOver:
      budget = Budget(
        periodStart: periodStart,
        spendablePerPeriodCents: 110_000
      )
      bills = []
    case .todayZero:
      budget = Budget(periodStart: periodStart, spendablePerPeriodCents: 0)
      bills = []
    case .setupWarning:
      // 1,200 - (1,100 + 250) - 100 = -250 available.
      budget = Budget(
        periodStart: periodStart,
        spendablePerPeriodCents: 120_000,
        savingsCents: 10_000
      )
      bills = [
        FixedBill(name: "Rent", amountCents: 110_000, dueDay: 1),
        FixedBill(name: "Car payment", amountCents: 25_000, dueDay: 15),
      ]
    }
    context.insert(budget)
    for bill in bills {
      context.insert(bill)
      budget.fixedBills.append(bill)
    }
    if self == .todayUndo {
      try CategoryService(context: context).createExpense(
        amountCents: 1_250,
        note: "Lunch with Sam",
        date: now,
        now: now
      )
    }
    if self == .todayNormal || self == .todayNear || self == .todayOver {
      let service = CategoryService(context: context)
      try service.seed()
      let categories = try service.categories()
      var amount = 2_500
      if self == .todayNear { amount = 9_500 }
      if self == .todayOver { amount = 12_500 }
      try service.createExpense(
        amountCents: amount,
        note: "Lunch with Sam",
        date: now.addingTimeInterval(-3_600),
        category: categories.first { $0.name == "Food" },
        now: now.addingTimeInterval(-3_600)
      )
      try service.createExpense(
        amountCents: -500,
        note: "Returned item",
        date: now,
        category: categories.first { $0.name == "Shopping" },
        now: now
      )
    }
    try context.save()
    return budget
  }
}
