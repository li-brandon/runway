import Foundation
import SwiftData

/// Launch arguments used by CI to take screenshots.
///
/// - `-RunwayInMemoryStore` uses a fresh in-memory store instead of the on-disk one.
/// - `-RunwayScreenshotScenario <name>` seeds the store and opens a sample screen (see
///   `ScreenshotScenario`). It's ignored without `-RunwayInMemoryStore`, so sample data can never
///   be written to the real store.
/// - `-RunwayScreenshotScrollTo spendable` scrolls setup to its amount fields, and
///   `-RunwayScreenshotScrollTo categories` scrolls History to its category totals. Both are
///   ignored without `-RunwayInMemoryStore`.
struct LaunchOptions: Equatable, Sendable {
  static let inMemoryStoreArgument = "-RunwayInMemoryStore"
  static let screenshotScenarioArgument = "-RunwayScreenshotScenario"
  static let screenshotScrollToArgument = "-RunwayScreenshotScrollTo"
  static let screenshotScrollTargets: Set<String> = ["spendable", "categories"]

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
      Self.screenshotScrollTargets.contains(arguments[index + 1])
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

  /// History of the current period, scrolled to its days.
  case historyList = "history-list"
  /// History of the previous, completed period: totals, carryover, and categories.
  case historyPeriodSummary = "history-period-summary"
  /// History with the edit sheet open on yesterday's latest expense.
  case historyEdit = "history-edit"
  /// The previous period with 500 expenses, scrolled to its oldest day, to check the list scrolls.
  case history500 = "history-500"

  var isHistory: Bool {
    switch self {
    case .historyList, .historyPeriodSummary, .historyEdit, .history500: true
    default: false
    }
  }

  var todayDate: Date? {
    switch self {
    case .todayNormal, .todayNear, .todayOver, .todayZero, .todayNoBudget:
      Self.fixedToday
    case .historyList, .historyPeriodSummary, .historyEdit, .history500:
      Self.fixedToday
    default:
      nil
    }
  }

  private static var fixedToday: Date? {
    Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 12))
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
    case .historyList, .historyPeriodSummary, .historyEdit, .history500:
      return try seedHistory(into: context, now: now, calendar: calendar)
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

  /// Two biweekly periods of everyday spending with $1,100 available and carryover on: a
  /// completed one starting 17 days before today, with some days over, and the current one
  /// through this morning. Includes a refund. `history-500` instead spreads 500 expenses over the
  /// completed period, about 36 a day from 7:00 every 20 minutes, and none in the current one.
  private func seedHistory(
    into context: ModelContext,
    now: Date,
    calendar: Calendar
  ) throws -> Budget {
    let today = calendar.startOfDay(for: now)
    let start = calendar.date(byAdding: .day, value: -17, to: today) ?? today
    let budget = Budget(
      periodLength: .biweekly,
      periodStart: start,
      spendablePerPeriodCents: 110_000
    )
    context.insert(budget)
    let service = CategoryService(context: context)
    try service.seed()
    let categories = try service.categories()
    let samples: [(note: String, category: String, cents: Int)] = [
      ("Coffee", "Food", 475),
      ("Weekly groceries", "Groceries", 6_240),
      ("Bus fare", "Transport", 275),
      ("Lunch", "Food", 1_380),
      ("Movie night", "Entertainment", 1_600),
      ("Running shoes", "Shopping", 8_900),
      ("Dinner out", "Food", 4_250),
      ("Gas", "Transport", 4_800),
      ("Phone case", "Shopping", 2_100),
      ("Returned shirt", "Shopping", -2_500),
      ("Farmers market", "Groceries", 2_350),
    ]
    var dates: [Date] = []
    if self == .history500 {
      for index in 0..<500 {
        let day = calendar.date(byAdding: .day, value: index * 14 / 500, to: start) ?? start
        let minutes = 420 + index % 36 * 20
        dates.append(calendar.date(byAdding: .minute, value: minutes, to: day) ?? day)
      }
    } else {
      for offset in 0...17 {
        let day = calendar.date(byAdding: .day, value: offset, to: start) ?? start
        // Two expenses a day, morning and evening; today has two morning ones before `now`.
        for hour in offset == 17 ? [8, 10] : [9, 19] {
          dates.append(calendar.date(byAdding: .hour, value: hour, to: day) ?? day)
        }
      }
    }
    for (index, date) in dates.enumerated() {
      let sample = samples[index % samples.count]
      try service.createExpense(
        amountCents: sample.cents,
        note: sample.note,
        date: date,
        category: categories.first { $0.name == sample.category },
        now: date
      )
    }
    try context.save()
    return budget
  }
}
