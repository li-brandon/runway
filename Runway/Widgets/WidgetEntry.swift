import Foundation
import SwiftData
import WidgetKit
import os

/// The figures a widget shows, all from `AllowanceEngine`.
struct WidgetAllowance: Equatable, Sendable {
  var remainingTodayCents: Int
  var remainingPeriodCents: Int
  var daysLeft: Int
  var status: TodayStatus

  init(_ result: AllowanceResult) {
    remainingTodayCents = result.remainingTodayCents
    remainingPeriodCents = result.remainingPeriodCents
    daysLeft = result.daysLeft
    status = TodayStatus(result)
  }

  init(remainingTodayCents: Int, remainingPeriodCents: Int, daysLeft: Int, status: TodayStatus) {
    self.remainingTodayCents = remainingTodayCents
    self.remainingPeriodCents = remainingPeriodCents
    self.daysLeft = daysLeft
    self.status = status
  }
}

/// What a widget shows from `date` on.
struct RunwayWidgetEntry: TimelineEntry, Equatable, Sendable {
  enum Content: Equatable, Sendable {
    case allowance(WidgetAllowance)
    case noBudget
    /// The store can't be read: the app hasn't moved it yet, or the device hasn't been unlocked.
    case storeNotReady
  }

  let date: Date
  let content: Content
  /// Whether the app lock is on, so amounts redact on a locked device.
  var amountsArePrivate = false

  /// Made-up figures for the widget gallery and placeholders, never the user's.
  static var sample: RunwayWidgetEntry {
    RunwayWidgetEntry(
      date: .now,
      content: .allowance(
        WidgetAllowance(
          remainingTodayCents: 4_250,
          remainingPeriodCents: 48_000,
          daysLeft: 9,
          status: .normal
        )
      )
    )
  }
}

/// The entries a widget shows until `reloadDate`.
struct WidgetTimelinePlan: Equatable, Sendable {
  let entries: [RunwayWidgetEntry]
  let reloadDate: Date
}

/// Builds widget timelines from the store. The figures are the same as Today's: the same budget
/// and expenses go through the same `AllowanceEngine` call.
enum WidgetTimelineBuilder {
  /// How soon to look again when the store can't be read.
  static let retryInterval: TimeInterval = 15 * 60

  /// Never throws: a store that can't be opened or read gives a `storeNotReady` entry.
  static func plan(
    loadContainer: () throws -> ModelContainer,
    amountsArePrivate: Bool,
    now: Date,
    calendar: Calendar
  ) -> WidgetTimelinePlan {
    do {
      let context = ModelContext(try loadContainer())
      context.autosaveEnabled = false
      return try plan(
        in: context,
        amountsArePrivate: amountsArePrivate,
        now: now,
        calendar: calendar
      )
    } catch {
      let reason = String(describing: error)
      RunwayModelContainer.logger.notice("Widget can't read the store: \(reason, privacy: .public)")
      return WidgetTimelinePlan(
        entries: [RunwayWidgetEntry(date: now, content: .storeNotReady)],
        reloadDate: now.addingTimeInterval(retryInterval)
      )
    }
  }

  /// Loads what `WidgetTimelinePlanner` needs from the store.
  private static func plan(
    in context: ModelContext,
    amountsArePrivate: Bool,
    now: Date,
    calendar: Calendar
  ) throws -> WidgetTimelinePlan {
    let midnight = nextMidnight(after: now, calendar: calendar)
    var descriptor = FetchDescriptor<Budget>(sortBy: [SortDescriptor(\.periodStart)])
    descriptor.fetchLimit = 1
    guard let budget = try context.fetch(descriptor).first else {
      return WidgetTimelinePlan(
        entries: [RunwayWidgetEntry(date: now, content: .noBudget)],
        reloadDate: midnight
      )
    }
    // Today adopts the current time zone first, so do the same. This is never saved.
    budget.adoptTimeZone(of: calendar)
    let snapshot = BudgetSnapshot(budget)
    let expenses = try context.fetch(FetchDescriptor<Expense>()).map { ExpenseSnapshot($0) }
    return WidgetTimelinePlanner(calendar: calendar).plan(
      budget: snapshot,
      expenses: expenses,
      amountsArePrivate: amountsArePrivate,
      now: now
    )
  }
}
