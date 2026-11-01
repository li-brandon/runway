import Foundation
import SwiftData
import Testing
import WidgetKit

@testable import Runway

/// Always approves, so a test can turn the app lock on.
private struct ApprovingAuthenticator: AppLockAuthenticating {
  func authenticate(reason: String) async -> AppLockAuthResult {
    .success
  }
}

struct WidgetTimelineTests {
  private let calendar = Calendar.gregorian("America/Chicago")

  private func plan(
    in container: ModelContainer,
    amountsArePrivate: Bool = false,
    now: Date
  ) -> WidgetTimelinePlan {
    WidgetTimelineBuilder.plan(
      loadContainer: { container },
      amountsArePrivate: amountsArePrivate,
      now: now,
      calendar: calendar
    )
  }

  /// A store with a saved 14-day budget from June 1, and one expense at `now` for `spentCents`.
  private func makeContainer(
    availableCents: Int = 140_000,
    spentCents: Int? = nil,
    now: Date
  ) throws -> ModelContainer {
    let container = try RunwayModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    context.insert(
      Budget(
        periodLength: .biweekly,
        periodStart: calendar.date(2026, 6, 1),
        spendablePerPeriodCents: availableCents,
        timeZoneIdentifier: calendar.timeZone.identifier
      )
    )
    let service = CategoryService(context: context)
    try service.seed()
    if let spentCents {
      try service.createExpense(amountCents: spentCents, date: now, now: now)
    }
    try context.save()
    return container
  }

  @Test("No budget gives the setup entry, reloading at midnight")
  func noBudget() throws {
    let now = calendar.date(2026, 6, 10, 12)
    let container = try RunwayModelContainer.make(inMemory: true)
    let result = plan(in: container, now: now)
    #expect(result.entries == [RunwayWidgetEntry(date: now, content: .noBudget)])
    #expect(result.reloadDate == calendar.date(2026, 6, 11))
  }

  @Test("A store that can't open gives the placeholder entry and tries again soon")
  func storeNotReady() {
    let now = calendar.date(2026, 6, 10, 12)
    let result = WidgetTimelineBuilder.plan(
      loadContainer: { throw RunwayStoreError.storeNotReady },
      amountsArePrivate: true,
      now: now,
      calendar: calendar
    )
    #expect(result.entries == [RunwayWidgetEntry(date: now, content: .storeNotReady)])
    #expect(result.reloadDate == now.addingTimeInterval(WidgetTimelineBuilder.retryInterval))
  }

  @Test("Figures match Today's engine call, for now and for the next midnight")
  func matchesEngine() throws {
    let now = calendar.date(2026, 6, 10, 12)
    let midnight = calendar.date(2026, 6, 11)
    let container = try makeContainer(spentCents: 2_500, now: now)
    let budget = BudgetSnapshot(
      periodLength: .biweekly,
      periodStart: calendar.date(2026, 6, 1),
      spendablePerPeriodCents: 140_000
    )
    let expenses = [expense(2_500, now)]
    let engine = AllowanceEngine(calendar: calendar)

    let result = plan(in: container, now: now)

    #expect(result.reloadDate == midnight)
    #expect(result.entries.map(\.date) == [now, midnight])
    let expected: [RunwayWidgetEntry.Content] = [now, midnight].map { date in
      .allowance(
        WidgetAllowance(
          engine.currentAllowance(budget: budget, expenses: expenses, now: date),
          calendar: calendar
        )
      )
    }
    #expect(result.entries.map(\.content) == expected)
    // $1,400 over the 5 days left, including June 10, is $280 a day, less the $25 spent.
    let today = WidgetAllowance(
      remainingTodayCents: 25_500,
      remainingPeriodCents: 137_500,
      daysLeft: 5,
      periodDays: 14,
      status: .normal
    )
    #expect(result.entries[0].content == .allowance(today))
  }

  @Test("Overspending keeps the negative amounts and the over status")
  func negative() throws {
    let now = calendar.date(2026, 6, 10, 12)
    let container = try makeContainer(spentCents: 150_000, now: now)
    let result = plan(in: container, now: now)
    let today = WidgetAllowance(
      remainingTodayCents: -122_000,
      remainingPeriodCents: -10_000,
      daysLeft: 5,
      periodDays: 14,
      status: .over
    )
    #expect(result.entries[0].content == .allowance(today))
  }

  @Test("A budget with nothing available shows zero with no allowance left")
  func zero() throws {
    let now = calendar.date(2026, 6, 10, 12)
    let container = try makeContainer(availableCents: 0, now: now)
    let result = plan(in: container, now: now)
    let today = WidgetAllowance(
      remainingTodayCents: 0,
      remainingPeriodCents: 0,
      daysLeft: 5,
      periodDays: 14,
      status: .noAllowance
    )
    #expect(result.entries[0].content == .allowance(today))
  }

  @Test("Paydays keep their calendar days after the device moves, as on Today, without saving")
  func adoptsTimeZone() throws {
    let now = calendar.date(2026, 6, 10, 12)
    let newYork = Calendar.gregorian("America/New_York")
    let container = try RunwayModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    context.insert(
      Budget(
        periodLength: .biweekly,
        periodStart: newYork.date(2026, 6, 1),
        spendablePerPeriodCents: 140_000,
        timeZoneIdentifier: newYork.timeZone.identifier
      )
    )
    try context.save()

    let result = plan(in: container, now: now)

    guard case .allowance(let allowance) = result.entries[0].content else {
      Issue.record("Expected an allowance entry")
      return
    }
    // Without adopting, the period would start at 11 PM on May 31 here and leave 4 days.
    #expect(allowance.daysLeft == 5)
    let budgets = try ModelContext(container).fetch(FetchDescriptor<Budget>())
    #expect(budgets.first?.timeZoneIdentifier == newYork.timeZone.identifier)
  }

  @Test("Entries carry the app lock setting")
  func privacy() throws {
    let now = calendar.date(2026, 6, 10, 12)
    let container = try makeContainer(now: now)
    let result = plan(in: container, amountsArePrivate: true, now: now)
    #expect(result.entries.allSatisfy { $0.amountsArePrivate })
  }

  @Test("The read-only store opens only once it exists")
  func readOnlyStore() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "RunwayTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "default.store")
    let now = calendar.date(2026, 6, 10, 12)

    let missing = WidgetTimelineBuilder.plan(
      loadContainer: { try RunwayModelContainer.makeReadOnly(url: url) },
      amountsArePrivate: false,
      now: now,
      calendar: calendar
    )
    #expect(missing.entries[0].content == .storeNotReady)

    let writable = try RunwayModelContainer.make(url: url)
    let context = ModelContext(writable)
    context.insert(
      Budget(periodStart: calendar.date(2026, 6, 1), spendablePerPeriodCents: 140_000)
    )
    try context.save()

    let ready = WidgetTimelineBuilder.plan(
      loadContainer: { try RunwayModelContainer.makeReadOnly(url: url) },
      amountsArePrivate: false,
      now: now,
      calendar: calendar
    )
    guard case .allowance = ready.entries[0].content else {
      Issue.record("Expected an allowance entry")
      return
    }
  }
}

struct LockScreenWidgetTests {
  private func allowance(
    today: Int = 4_250,
    daysLeft: Int = 9,
    periodDays: Int = 14
  ) -> WidgetAllowance {
    WidgetAllowance(
      remainingTodayCents: today,
      remainingPeriodCents: 48_000,
      daysLeft: daysLeft,
      periodDays: periodDays,
      status: .normal
    )
  }

  @Test("The inline text reads amount, then days, abbreviating large amounts")
  func inlineText() {
    let cases: [(cents: Int, days: Int, expected: String)] = [
      (4_250, 9, "$42.50 today · 9 days left"),
      (4_250, 1, "$42.50 today · 1 day left"),
      (0, 0, "$0.00 today · 0 days left"),
      (-12_500, 14, "-$125.00 today · 14 days left"),
      (12_345_678, 11, "$123.5K today · 11 days left"),
      (-10_000_000_000_000, 11, "-$100B today · 11 days left"),
    ]
    for item in cases {
      let text = LockScreenText.inline(
        allowance(today: item.cents, daysLeft: item.days),
        locale: Money.fixedLocale
      )
      #expect(text == item.expected)
      #expect(!text.contains("…"))
    }
  }

  @Test("The inline fallback keeps the amount and days")
  func compactInlineText() {
    let text = LockScreenText.compactInline(
      allowance(today: 12_345_678, daysLeft: 11),
      locale: Money.fixedLocale
    )
    #expect(text == "$123.5K · 11d")
  }

  @Test("VoiceOver gets the full amount")
  func accessibilityText() {
    let text = LockScreenText.accessibility(
      allowance(today: 12_345_678, daysLeft: 1),
      locale: Money.fixedLocale
    )
    #expect(text == "$123,456.78 today, 1 day left")
  }

  @Test("The rectangular days text is singular only for one day")
  func rectangularDaysLeft() {
    #expect(LockScreenText.daysLeft(0) == "0 days left")
    #expect(LockScreenText.daysLeft(1) == "1 day left")
    #expect(LockScreenText.daysLeft(14) == "14 days left")
  }

  @Test("The rectangular amount ends abbreviated at its smallest size, without an ellipsis")
  func rectangularAmount() throws {
    let steps = LockScreenText.rectangularAmountSteps
    let candidates = AmountCandidate.candidates(
      cents: -10_000_000_000_000,
      steps: steps,
      locale: Money.fixedLocale
    )
    let last = try #require(candidates.last)
    #expect(last.text == "-$100B")
    #expect(last.style == steps.last)
    let texts = candidates.map { $0.text }
    #expect(!texts.contains { $0.contains("…") })
  }

  @Test("The gauge shows days elapsed over the period's length")
  func gaugeFraction() {
    let cases: [(daysLeft: Int, periodDays: Int, expected: Double)] = [
      (14, 14, 0),
      (5, 14, 9.0 / 14.0),
      (1, 14, 13.0 / 14.0),
      (0, 14, 1),
      (10, 30, 20.0 / 30.0),
      // Out-of-range figures stay on the gauge.
      (20, 14, 0),
      (0, 0, 1),
    ]
    for item in cases {
      let fraction = allowance(daysLeft: item.daysLeft, periodDays: item.periodDays).elapsedFraction
      #expect(fraction == item.expected)
    }
  }

  @Test("A monthly budget's gauge uses that month's length")
  func monthlyPeriodDays() throws {
    let calendar = Calendar.gregorian("America/Chicago")
    let now = calendar.date(2026, 6, 10, 12)
    let container = try RunwayModelContainer.make(inMemory: true)
    let context = ModelContext(container)
    context.insert(
      Budget(
        periodLength: .monthly,
        periodStart: calendar.date(2026, 6, 1),
        spendablePerPeriodCents: 140_000,
        timeZoneIdentifier: calendar.timeZone.identifier
      )
    )
    try context.save()

    let result = WidgetTimelineBuilder.plan(
      loadContainer: { container },
      amountsArePrivate: false,
      now: now,
      calendar: calendar
    )

    guard case .allowance(let allowance) = result.entries[0].content else {
      Issue.record("Expected an allowance entry")
      return
    }
    #expect(allowance.periodDays == 30)
    #expect(allowance.daysLeft == 21)
    #expect(allowance.elapsedFraction == 9.0 / 30.0)
  }

  @Test("Only accessory families use the lock-screen layouts")
  func families() {
    #expect(LockScreenWidgetContent.Family(.accessoryCircular) == .circular)
    #expect(LockScreenWidgetContent.Family(.accessoryRectangular) == .rectangular)
    #expect(LockScreenWidgetContent.Family(.accessoryInline) == .inline)
    #expect(LockScreenWidgetContent.Family(.systemSmall) == nil)
    #expect(LockScreenWidgetContent.Family(.systemMedium) == nil)
  }
}

struct WidgetPrivacyTests {
  @Test("Amounts are private until the app says the lock is off")
  func failsSafe() throws {
    #expect(WidgetPrivacy.amountsArePrivate(in: nil))
    let suiteName = "WidgetPrivacyTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    #expect(WidgetPrivacy.amountsArePrivate(in: defaults))
    WidgetPrivacy.share(appLockEnabled: false, in: defaults)
    #expect(!WidgetPrivacy.amountsArePrivate(in: defaults))
    WidgetPrivacy.share(appLockEnabled: true, in: defaults)
    #expect(WidgetPrivacy.amountsArePrivate(in: defaults))
  }

  @MainActor
  @Test("The app lock shares its setting at launch and when it changes")
  func controllerShares() async throws {
    let appSuite = "WidgetPrivacyTests-\(UUID().uuidString)"
    let appDefaults = try #require(UserDefaults(suiteName: appSuite))
    defer { appDefaults.removePersistentDomain(forName: appSuite) }
    let sharedSuite = "WidgetPrivacyTests-\(UUID().uuidString)"
    let shared = try #require(UserDefaults(suiteName: sharedSuite))
    defer { shared.removePersistentDomain(forName: sharedSuite) }

    let lock = AppLockController(
      authenticator: ApprovingAuthenticator(),
      defaults: appDefaults,
      sharedDefaults: shared
    )
    #expect(!WidgetPrivacy.amountsArePrivate(in: shared))

    await lock.setEnabled(true)
    #expect(lock.isEnabled)
    #expect(WidgetPrivacy.amountsArePrivate(in: shared))

    await lock.setEnabled(false)
    #expect(!WidgetPrivacy.amountsArePrivate(in: shared))
  }

  @MainActor
  @Test("A lock turned on before widgets existed is shared at launch")
  func sharesExistingLock() throws {
    let appSuite = "WidgetPrivacyTests-\(UUID().uuidString)"
    let appDefaults = try #require(UserDefaults(suiteName: appSuite))
    defer { appDefaults.removePersistentDomain(forName: appSuite) }
    let sharedSuite = "WidgetPrivacyTests-\(UUID().uuidString)"
    let shared = try #require(UserDefaults(suiteName: sharedSuite))
    defer { shared.removePersistentDomain(forName: sharedSuite) }
    shared.set(false, forKey: WidgetPrivacy.appLockEnabledKey)
    appDefaults.set(true, forKey: AppLockController.enabledKey)

    _ = AppLockController(
      authenticator: ApprovingAuthenticator(),
      defaults: appDefaults,
      sharedDefaults: shared
    )

    #expect(WidgetPrivacy.amountsArePrivate(in: shared))
  }
}

struct WidgetIntegrationTests {
  @Test("Only the today link opens Today")
  func deepLink() throws {
    let uppercase = try #require(URL(string: "RUNWAY://TODAY"))
    let otherScreen = try #require(URL(string: "runway://history"))
    let otherScheme = try #require(URL(string: "https://today"))
    #expect(AppDeepLink(url: AppDeepLink.todayURL) == .today)
    #expect(AppDeepLink(url: uppercase) == .today)
    #expect(AppDeepLink(url: otherScreen) == nil)
    #expect(AppDeepLink(url: otherScheme) == nil)
  }

  @Test("The today link goes from History back to Today")
  func openingLinkLeavesHistory() throws {
    let uppercase = try #require(URL(string: "RUNWAY://TODAY"))
    for url in [AppDeepLink.todayURL, uppercase] {
      var navigation = TodayNavigation(showsHistory: true)
      navigation.open(url)
      #expect(navigation == TodayNavigation())
    }
  }

  @Test("Opening a link leaves an open sheet where it is, so an editor keeps its draft")
  func openingLinkKeepsOpenSheets() {
    let open = [
      TodayNavigation(todayPresentsSheet: true),
      TodayNavigation(showsHistory: true, todayPresentsSheet: true),
      TodayNavigation(showsHistory: true, historyPresentsSheet: true),
    ]
    for before in open {
      var navigation = before
      navigation.open(AppDeepLink.todayURL)
      #expect(navigation == before)
    }
  }

  @Test("The today link on Today changes nothing")
  func openingLinkOnToday() {
    var navigation = TodayNavigation()
    navigation.open(AppDeepLink.todayURL)
    #expect(navigation == TodayNavigation())
  }

  @Test("An unknown link changes nothing")
  func openingUnknownLink() throws {
    let otherScreen = try #require(URL(string: "runway://history"))
    let otherScheme = try #require(URL(string: "https://today"))
    for url in [otherScreen, otherScheme] {
      var navigation = TodayNavigation(showsHistory: true)
      navigation.open(url)
      #expect(navigation == TodayNavigation(showsHistory: true))
    }
  }

  @Test("An import or reset changes the generation, which is what closes sheets")
  func dataReplaceChangesGeneration() {
    var state = RootViewState()
    state.dataDidReplace()
    #expect(state.dataGeneration == 1)
  }

  @Test("The app registers the scheme the widgets link to")
  func urlSchemeRegistered() throws {
    let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
    let schemes = (types ?? []).flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
    let scheme = try #require(AppDeepLink.todayURL.scheme)
    #expect(schemes.contains(scheme))
  }

  @Test("The app embeds the widget extension, with a matching identity and version")
  func extensionEmbedded() throws {
    let plugIns = try #require(Bundle.main.builtInPlugInsURL)
    let widgets = try #require(Bundle(url: plugIns.appending(path: "RunwayWidgets.appex")))
    let appIdentifier = try #require(Bundle.main.bundleIdentifier)
    #expect(widgets.bundleIdentifier == "\(appIdentifier).widgets")
    let info = widgets.object(forInfoDictionaryKey: "NSExtension") as? [String: Any]
    let point = info?["NSExtensionPointIdentifier"] as? String
    #expect(point == "com.apple.widgetkit-extension")
    for key in ["CFBundleShortVersionString", "CFBundleVersion"] {
      let version = widgets.object(forInfoDictionaryKey: key) as? String
      #expect(version == Bundle.main.object(forInfoDictionaryKey: key) as? String)
    }
  }
}
