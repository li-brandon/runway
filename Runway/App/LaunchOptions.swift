import Foundation
import SwiftData

/// Launch arguments used by CI to take screenshots.
///
/// - `-RunwayInMemoryStore` uses a fresh in-memory store instead of the on-disk one.
/// - `-RunwayScreenshotScenario <name>` seeds the store and opens budget setup (see
///   `ScreenshotScenario`). It's ignored without `-RunwayInMemoryStore`, so sample data can never
///   be written to the real store.
struct LaunchOptions: Equatable, Sendable {
  static let inMemoryStoreArgument = "-RunwayInMemoryStore"
  static let screenshotScenarioArgument = "-RunwayScreenshotScenario"

  var usesInMemoryStore = false
  var screenshotScenario: ScreenshotScenario?

  init(arguments: [String]) {
    usesInMemoryStore = arguments.contains(Self.inMemoryStoreArgument)
    guard usesInMemoryStore,
      let index = arguments.firstIndex(of: Self.screenshotScenarioArgument),
      index + 1 < arguments.count
    else { return }
    screenshotScenario = ScreenshotScenario(rawValue: arguments[index + 1])
  }
}

/// Sample states for CI screenshots of budget setup.
enum ScreenshotScenario: String, CaseIterable, Sendable {
  /// First launch: no budget, so setup shows its defaults.
  case setupEmpty = "setup-empty"
  /// A filled-in budget with money left to spend, reopened from Settings.
  case setupFilled = "setup-filled"
  /// A budget whose bills and savings exceed spendable, reopened from Settings.
  case setupWarning = "setup-warning"

  /// Inserts and saves this scenario's budget, if it has one. Its period started three days
  /// before `now`.
  @discardableResult
  func seed(into context: ModelContext, now: Date, calendar: Calendar) throws -> Budget? {
    let today = calendar.startOfDay(for: now)
    let periodStart = calendar.date(byAdding: .day, value: -3, to: today) ?? today
    let budget: Budget
    let bills: [FixedBill]
    switch self {
    case .setupEmpty:
      return nil
    case .setupFilled:
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
    try context.save()
    return budget
  }
}
