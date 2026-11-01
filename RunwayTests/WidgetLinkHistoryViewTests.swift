import Foundation
import SwiftData
import SwiftUI
import Testing
import UIKit

@testable import Runway

/// The widget link against the real `ContentView` and `HistoryView`, hosted in a window of the test
/// host's scene. Awaiting yields the main actor, so the host's run loop keeps updating the views.
@MainActor
struct WidgetLinkHistoryViewTests {
  @Test("A widget link leaves History alone while Undo is pending, and Undo restores the item")
  func widgetLinkKeepsHistoryUndo() async throws {
    let container = try RunwayModelContainer.make(inMemory: true)
    let context = container.mainContext
    try CategoryService(context: context).seed()
    let budget = Budget(
      periodLength: .weekly,
      periodStart: Calendar.current.startOfDay(for: .now),
      spendablePerPeriodCents: 70_000
    )
    context.insert(budget)
    let lunch = try CategoryService(context: context).createExpense(amountCents: 900, note: "Lunch")
    try context.save()

    let hooks = TodayViewHooks()
    let window = try await makeWindow()
    window.rootViewController = UIHostingController(
      rootView: ContentView(budget: budget)
        .environment(\.todayViewHooks, hooks)
        .modelContainer(container)
    )
    window.makeKeyAndVisible()
    defer {
      window.isHidden = true
      window.rootViewController = nil
    }

    let todayAppeared = await waitUntil { hooks.showHistory != nil && hooks.openURL != nil }
    try #require(todayAppeared)
    let showHistory = try #require(hooks.showHistory)
    let openURL = try #require(hooks.openURL)

    showHistory()
    let historyAppeared = await waitUntil { hooks.deleteExpense != nil }
    try #require(historyAppeared)

    let delete = try #require(hooks.deleteExpense)
    delete(lunch)
    let notesAfterDelete = try savedNotes(in: context)
    #expect(notesAfterDelete.isEmpty)
    let bannerAppeared = await waitUntil { hooks.undoDelete != nil }
    try #require(bannerAppeared)

    // Long enough for a pop to finish, and well inside the five-second undo.
    openURL(AppDeepLink.todayURL)
    let leftHistory = await waitUntil(timeout: .seconds(1)) {
      hooks.deleteExpense == nil || hooks.undoDelete == nil
    }
    #expect(!leftHistory)

    let undo = try #require(hooks.undoDelete)
    undo()
    let notesAfterUndo = try savedNotes(in: context)
    #expect(notesAfterUndo == ["Lunch"])
    let bannerClosed = await waitUntil { hooks.undoDelete == nil }
    #expect(bannerClosed)
    let historyAfterUndo = hooks.deleteExpense != nil
    #expect(historyAfterUndo)

    // With nothing left to undo the same link goes back to Today, so the check above could fail.
    openURL(AppDeepLink.todayURL)
    let returnedToToday = await waitUntil { hooks.deleteExpense == nil }
    #expect(returnedToToday)
  }

  private func makeWindow() async throws -> UIWindow {
    var scene: UIWindowScene?
    _ = await waitUntil {
      scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
      return scene != nil
    }
    return UIWindow(windowScene: try #require(scene))
  }

  private func savedNotes(in context: ModelContext) throws -> [String] {
    try context.fetch(FetchDescriptor<Expense>()).map { $0.note }
  }

  /// Polls `condition` until it holds, and returns whether it did before `timeout`.
  private func waitUntil(
    timeout: Duration = .seconds(3),
    _ condition: () -> Bool
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
      guard clock.now < deadline else { return false }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return true
  }
}
