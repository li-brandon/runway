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
///   ignored without `-RunwayInMemoryStore`. The `carryover` target scrolls to the carryover
///   setting and is the default for `budget-change-carryover`. The `today` target scrolls Today to
///   what's left to spend, `bills` scrolls This Period to its bills, `extras` scrolls it to the
///   end of its last extra money row, `before-budget` scrolls History to the end of its Before
///   budget section, `extra-money-row` scrolls History to an extra money row, and
///   `extra-money-delete` scrolls the extra money edit sheet to its Delete button.
struct LaunchOptions: Equatable, Sendable {
  static let inMemoryStoreArgument = "-RunwayInMemoryStore"
  static let screenshotScenarioArgument = "-RunwayScreenshotScenario"
  static let screenshotScrollToArgument = "-RunwayScreenshotScrollTo"
  static let screenshotScrollTargets: Set<String> = [
    "spendable",
    "categories",
    "carryover",
    "today",
    "bills",
    "extras",
    "before-budget",
    "extra-money-row",
    "extra-money-delete",
  ]

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
    if screenshotScenario == .budgetChangeCarryover {
      screenshotScrollTo = "carryover"
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
  /// Six-figure amounts on Today: $123,456.78 left, with large spent and allowance figures.
  case todayLargeAmount = "today-large-amount"
  /// Today at the import maximum: $100B left and $100B spent, abbreviated when they can't fit.
  case todayImportMax = "today-import-max"

  case spendingDay = "spending-day"
  case spendingWeek = "spending-week"
  case spendingMonth = "spending-month"
  case spendingMonthRolling = "spending-month-rolling"

  var spendingSelection: (view: SpendingView, mode: SpendingWindowMode)? {
    switch self {
    case .spendingDay: (.day, .calendar)
    case .spendingWeek: (.week, .calendar)
    case .spendingMonth: (.month, .calendar)
    case .spendingMonthRolling: (.month, .rolling)
    default: nil
    }
  }

  /// History of the current period, scrolled to its days.
  case historyList = "history-list"
  /// History of the previous, completed period: totals, carryover, and categories.
  case historyPeriodSummary = "history-period-summary"
  /// History with the edit sheet open on yesterday's latest expense.
  case historyEdit = "history-edit"
  /// The previous period with 500 expenses, scrolled to its oldest day, to check the list scrolls.
  case history500 = "history-500"
  /// The oldest period's page, scrolled to the expenses and money dated before the budget's start.
  case historyBeforeBudget = "history-before-budget"
  /// The oldest period's page, scrolled to bill marks dated before the budget's start.
  case historyBeforeBudgetBills = "history-before-budget-bills"
  /// The bill entry edit sheet open on a paid mark dated before the budget's start.
  case historyBillEntryEdit = "history-bill-entry-edit"
  /// The previous period, scrolled to a day with an extra money row among its expenses.
  case historyExtraMoney = "history-extra-money"
  /// The extra money edit sheet open on a negative imported amount, showing the sign control.
  case extraMoneyEditNegative = "extra-money-edit-negative"

  /// Budget editing with spendable raised mid-period, noting that new amounts apply from today.
  case budgetChangeAmounts = "budget-change-amounts"
  /// Switching to monthly periods mid-period, with the confirm dialog open.
  case budgetChangePeriod = "budget-change-period"
  /// Carryover switched off mid-period, noting it takes effect next period.
  case budgetChangeCarryover = "budget-change-carryover"
  /// The Add Money sheet filled in with a gift.
  case budgetChangeAddMoney = "budget-change-add-money"
  /// This period's extra money and bills: a gift, Rent paid, and Phone skipped.
  case budgetChangeBills = "budget-change-bills"
  /// This Period with large extra money, one with a long note, and large bills.
  case extraMoney = "extra-money"

  /// Privacy & Data with the app lock on.
  case privacySettings = "privacy-settings"
  /// The lock screen over Today. Its authenticator never shows a system prompt.
  case privacyLocked = "privacy-locked"
  /// Privacy & Data with the import confirm alert open on a backup of the sample data.
  case privacyImportConfirm = "privacy-import-confirm"
  /// Privacy & Data with the reset confirm alert open.
  case privacyResetConfirm = "privacy-reset-confirm"

  var isPrivacy: Bool {
    switch self {
    case .privacySettings, .privacyLocked, .privacyImportConfirm, .privacyResetConfirm: true
    default: false
    }
  }

  /// Opens Privacy & Data directly at launch.
  var opensPrivacyData: Bool {
    isPrivacy && self != .privacyLocked
  }

  /// Opens setup on a saved budget at launch.
  var opensBudgetSetup: Bool {
    switch self {
    case .setupFilled, .setupWarning, .budgetChangeAmounts, .budgetChangePeriod,
      .budgetChangeCarryover:
      true
    default:
      false
    }
  }

  /// Opens This Period at launch.
  var opensPeriodMoney: Bool {
    self == .budgetChangeBills || self == .extraMoney
  }

  /// Makes this scenario's unsaved edits to the setup screen's draft.
  func prepare(_ draft: inout BudgetDraft) {
    switch self {
    case .budgetChangeAmounts:
      draft.spendableText = BudgetDraft.text(fromCents: 260_000)
    case .budgetChangePeriod:
      draft.periodLength = .monthly
    case .budgetChangeCarryover:
      draft.carryoverEnabled = false
    default:
      break
    }
  }

  var isHistory: Bool {
    switch self {
    case .historyList, .historyPeriodSummary, .historyEdit, .history500, .historyBeforeBudget,
      .historyBeforeBudgetBills, .historyBillEntryEdit, .historyExtraMoney,
      .extraMoneyEditNegative:
      true
    default:
      false
    }
  }

  var todayDate: Date? {
    switch self {
    case .todayNormal, .todayNear, .todayOver, .todayZero, .todayNoBudget, .todayLargeAmount,
      .todayImportMax, .extraMoney, .spendingDay, .spendingWeek, .spendingMonth,
      .spendingMonthRolling:
      Self.fixedToday
    case .historyList, .historyPeriodSummary, .historyEdit, .history500, .historyBeforeBudget,
      .historyBeforeBudgetBills, .historyBillEntryEdit, .historyExtraMoney,
      .extraMoneyEditNegative:
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
    case .spendingDay, .spendingWeek, .spendingMonth, .spendingMonthRolling:
      return try seedSpending(into: context, now: now, calendar: calendar)
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
    case .setupFilled, .quickLogEmpty, .quickLogFilled, .quickLogNote, .todayUndo,
      .budgetChangeAmounts, .budgetChangePeriod, .budgetChangeCarryover, .budgetChangeAddMoney,
      .budgetChangeBills, .privacySettings, .privacyLocked, .privacyImportConfirm,
      .privacyResetConfirm:
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
    case .todayLargeAmount, .extraMoney:
      // 1,919,750.94 - (123,456.00 + 34,567.89) = 1,761,727.05 available.
      budget = Budget(
        periodStart: periodStart,
        spendablePerPeriodCents: 191_975_094
      )
      bills = [
        FixedBill(name: "Rent", amountCents: 12_345_600, dueDay: 1),
        FixedBill(name: "Car payment", amountCents: 3_456_789, dueDay: 15),
      ]
    case .todayZero, .todayImportMax:
      budget = Budget(periodStart: periodStart, spendablePerPeriodCents: 0)
      bills = []
    case .historyList, .historyPeriodSummary, .historyEdit, .history500, .historyBeforeBudget,
      .historyBeforeBudgetBills, .historyBillEntryEdit, .historyExtraMoney,
      .extraMoneyEditNegative:
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
    if self == .budgetChangeBills {
      budget.addExtraMoney(cents: 15_000, note: "Birthday gift", now: now, calendar: calendar)
      let rent = bills[0]
      budget.setStatus(.paid(cents: rent.amountCents), of: rent, now: now, calendar: calendar)
      budget.setStatus(.skipped, of: bills[1], now: now, calendar: calendar)
    }
    if self == .todayLargeAmount || self == .extraMoney {
      budget.addExtraMoney(cents: 9_876_543, note: "Signing bonus", now: now, calendar: calendar)
    }
    if self == .extraMoney {
      // Dated yesterday so it reliably sorts last, below the newer bonus.
      budget.addExtraMoney(
        cents: 1_234_567,
        note: "Refund of the security deposit from the apartment we moved out of last spring",
        now: calendar.date(byAdding: .day, value: -1, to: now) ?? now,
        calendar: calendar
      )
    }
    if self == .todayLargeAmount {
      // (1,761,727.05 + 98,765.43 extra) / 11 days = 169,135.68, less 45,678.90 = 123,456.78 left.
      let service = CategoryService(context: context)
      try service.seed()
      try service.createExpense(
        amountCents: 4_567_890,
        note: "Car down payment",
        date: now.addingTimeInterval(-3_600),
        category: service.categories().first { $0.name == "Shopping" },
        now: now.addingTimeInterval(-3_600)
      )
    }
    if self == .todayImportMax {
      // Each amount is within the import limit: 22 x 100B extra / 11 days = 200B, less 100B spent.
      let maximum = DataImport.maximumMagnitudeCents
      for _ in 0..<22 {
        budget.addExtraMoney(cents: maximum, note: "Windfall", now: now, calendar: calendar)
      }
      let service = CategoryService(context: context)
      try service.seed()
      try service.createExpense(
        amountCents: maximum,
        note: "Island",
        date: now.addingTimeInterval(-3_600),
        category: service.categories().first { $0.name == "Shopping" },
        now: now.addingTimeInterval(-3_600)
      )
    }
    if self == .todayUndo || isPrivacy {
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

  /// Seventy days cover both calendar and rolling comparisons, with a higher recent spend.
  private func seedSpending(
    into context: ModelContext,
    now: Date,
    calendar: Calendar
  ) throws -> Budget {
    let today = calendar.startOfDay(for: now)
    let start = calendar.date(byAdding: .day, value: -69, to: today)!
    let budget = Budget(
      periodLength: .weekly,
      periodStart: start,
      spendablePerPeriodCents: 70_000,
      carryoverEnabled: false
    )
    context.insert(budget)
    let service = CategoryService(context: context)
    for offset in 0..<70 {
      let day = calendar.date(byAdding: .day, value: offset, to: start)!
      try service.createExpense(
        amountCents: 1_000 + offset * 50,
        note: "Daily spending",
        date: day,
        now: day
      )
    }
    try context.save()
    return budget
  }

  /// Two biweekly periods of everyday spending with $1,100 available and carryover on: a
  /// completed one starting 17 days before today, with some days over, and the current one
  /// through this morning. Includes a refund. `history-500` instead spreads 500 expenses over the
  /// completed period, about 36 a day from 7:00 every 20 minutes, and none in the current one.
  /// `history-before-budget` adds three expenses and a gift in the days before the budget's start,
  /// and `history-before-budget-bills` two bills, covered by more spendable so $1,100 stays
  /// available, with a paid, a skipped, and a cleared mark before it (the last for a deleted bill).
  /// `history-bill-entry-edit` seeds the same. `history-extra-money` adds a gift, and
  /// `extra-money-edit-negative` a negative amount as from a backup, on the completed period's last
  /// day.
  private func seedHistory(
    into context: ModelContext,
    now: Date,
    calendar: Calendar
  ) throws -> Budget {
    let today = calendar.startOfDay(for: now)
    let start = calendar.date(byAdding: .day, value: -17, to: today) ?? today
    let seedsBillMarks = self == .historyBeforeBudgetBills || self == .historyBillEntryEdit
    let budget = Budget(
      periodLength: .biweekly,
      periodStart: start,
      spendablePerPeriodCents: seedsBillMarks ? 224_500 : 110_000
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
    if self == .historyBeforeBudget {
      let earlier: [(note: String, category: String, cents: Int, daysBefore: Int)] = [
        ("Moving truck", "Transport", 18_900, 2),
        ("Returned lamp", "Shopping", -3_500, 4),
        ("Housewarming dinner", "Food", 6_425, 6),
      ]
      for sample in earlier {
        let day = calendar.date(byAdding: .day, value: -sample.daysBefore, to: start) ?? start
        let date = calendar.date(byAdding: .hour, value: 18, to: day) ?? day
        try service.createExpense(
          amountCents: sample.cents,
          note: sample.note,
          date: date,
          category: categories.first { $0.name == sample.category },
          now: date
        )
      }
      budget.addExtraMoney(
        cents: 25_000,
        note: "Moving-in gift",
        now: calendar.date(byAdding: .day, value: -3, to: start) ?? start,
        calendar: calendar
      )
    }
    if seedsBillMarks {
      let rent = FixedBill(name: "Rent", amountCents: 110_000, dueDay: 1)
      let phone = FixedBill(name: "Phone", amountCents: 4_500, dueDay: 12)
      for bill in [rent, phone] {
        context.insert(bill)
        budget.fixedBills.append(bill)
      }
      budget.setStatus(
        .paid(cents: 105_000),
        of: rent,
        now: calendar.date(byAdding: .day, value: -3, to: start) ?? start,
        calendar: calendar
      )
      budget.setStatus(
        .skipped,
        of: phone,
        now: calendar.date(byAdding: .day, value: -5, to: start) ?? start,
        calendar: calendar
      )
      let cleared = BillPayment(
        isSkipped: false,
        isCleared: true,
        plannedCents: 6_000,
        paidCents: 0,
        adjustmentCents: 0,
        sequence: 3,
        date: calendar.date(byAdding: .day, value: -7, to: start) ?? start
      )
      context.insert(cleared)
      budget.billPayments.append(cleared)
    }
    let completedLastDay = calendar.date(byAdding: .day, value: 13, to: start) ?? start
    if self == .historyExtraMoney {
      budget.addExtraMoney(
        cents: 15_000,
        note: "Birthday gift",
        now: completedLastDay,
        calendar: calendar
      )
    }
    if self == .extraMoneyEditNegative {
      budget.addExtraMoney(
        cents: -4_250,
        note: "Bank correction",
        now: completedLastDay,
        calendar: calendar
      )
    }
    try context.save()
    return budget
  }
}
