import Foundation
import SwiftData

// Maps the SwiftData models to the engine's value types so `AllowanceEngine` stays pure.

extension BudgetSnapshot {
  /// Uses the budget's available amount (spendable − fixed bills − savings) as the per-period
  /// money, and includes its carryover, amount, and schedule histories sorted by `effectiveAt`
  /// as the engine requires. Extra money includes what marked bills give back.
  init(_ budget: Budget) {
    let carryover = budget.carryoverChanges.sorted { $0.effectiveAt < $1.effectiveAt }
    let amounts = budget.amountChanges.sorted { $0.effectiveAt < $1.effectiveAt }
    let schedules = budget.scheduleChanges.sorted { $0.effectiveAt < $1.effectiveAt }
    let extra = budget.extraMoney.map { extra in
      ExtraMoneySnapshot(amountCents: extra.amountCents, date: extra.date)
    }
    let bills = budget.billPayments.compactMap { payment -> ExtraMoneySnapshot? in
      let cents = payment.plannedCents - payment.paidCents
      guard cents != 0 else { return nil }
      return ExtraMoneySnapshot(amountCents: cents, date: payment.date)
    }
    self.init(
      periodLength: budget.periodLength,
      periodStart: budget.periodStart,
      spendablePerPeriodCents: budget.availablePerPeriodCents,
      carryoverEnabled: budget.carryoverEnabled,
      carryoverChanges: carryover.map { CarryoverChangeSnapshot($0) },
      amountChanges: amounts.map { change in
        AmountChangeSnapshot(
          previousCents: change.previousAvailableCents,
          effectiveAt: change.effectiveAt
        )
      },
      scheduleChanges: schedules.map { change in
        ScheduleChangeSnapshot(
          previousPeriodLength: change.previousPeriodLength,
          previousPeriodStart: change.previousPeriodStart,
          effectiveAt: change.effectiveAt
        )
      },
      extraMoney: extra + bills
    )
  }
}

extension CarryoverChangeSnapshot {
  init(_ change: CarryoverChange) {
    self.init(
      enabled: change.enabled,
      previousEnabled: change.previousEnabled,
      effectiveAt: change.effectiveAt
    )
  }
}

extension ExpenseSnapshot {
  init(_ expense: Expense) {
    self.init(amountCents: expense.amountCents, date: expense.date)
  }
}

extension HistoryExpense where CategoryID == PersistentIdentifier? {
  init(_ expense: Expense) {
    self.init(
      amountCents: expense.amountCents,
      date: expense.date,
      categoryID: expense.category?.persistentModelID
    )
  }
}

extension Budget {
  /// What each period leaves for day-to-day spending: spendable − fixed bills − savings. Can be
  /// zero or negative.
  var availablePerPeriodCents: Int {
    spendablePerPeriodCents - fixedBills.reduce(0) { $0 + $1.amountCents } - savingsCents
  }

  /// Turns carryover on or off from the next period boundary after `now`, recording the change
  /// so the current period's carry-in stays as it was.
  ///
  /// Setting the value already set does nothing. Switching back before the boundary cancels the
  /// pending change instead of recording a second one, so there is at most one pending change and
  /// at most one change per boundary, which keeps sorting by `effectiveAt` unambiguous.
  func setCarryover(_ enabled: Bool, now: Date, calendar: Calendar) {
    guard enabled != carryoverEnabled else { return }
    let previous = carryoverEnabled
    carryoverEnabled = enabled
    reschedulePendingCarryoverChange(now: now, calendar: calendar, previousSetting: previous)
  }

  /// Changes the period length and start (payday) from today: the current period ends at the
  /// start of today and the new schedule's first period starts today (see
  /// `BudgetSnapshot.changingSchedule`). Earlier days keep the schedule they had, recorded in
  /// `scheduleChanges`. A pending carryover change moves to the new next boundary after `now`, or
  /// is dropped if the setting in effect already matches it.
  func updatePeriod(_ length: PeriodLength, start: Date, now: Date, calendar: Calendar) {
    guard length != periodLength || start != periodStart else { return }
    let before = BudgetSnapshot(self)
    let after = before.changingSchedule(to: length, start: start, now: now, calendar: calendar)
    if after.scheduleChanges.count > before.scheduleChanges.count,
      let added = after.scheduleChanges.last
    {
      let change = ScheduleChange(
        previousPeriodLength: added.previousPeriodLength,
        previousPeriodStart: added.previousPeriodStart,
        effectiveAt: added.effectiveAt
      )
      modelContext?.insert(change)
      scheduleChanges.append(change)
    } else if after.scheduleChanges.count < before.scheduleChanges.count,
      let latest = scheduleChanges.max(by: { $0.effectiveAt < $1.effectiveAt })
    {
      scheduleChanges.removeAll { $0 === latest }
      modelContext?.delete(latest)
    }
    periodLength = after.periodLength
    periodStart = after.periodStart
    reschedulePendingCarryoverChange(
      now: now,
      calendar: calendar,
      previousSetting: carryoverEnabled
    )
  }

  /// Leaves at most one pending change, at the next boundary after `now`, taking the setting
  /// from the one in effect to `carryoverEnabled`.
  ///
  /// A change is pending if it hasn't applied by the start of the period containing `now`, judged
  /// by the current schedule (a period change before the budget's first day can turn an applied
  /// change back into a pending one). The setting in effect comes from the last applied change,
  /// else the first pending
  /// change's `previousEnabled`, else `previousSetting` when there is no history at all.
  private func reschedulePendingCarryoverChange(
    now: Date,
    calendar: Calendar,
    previousSetting: Bool
  ) {
    let engine = AllowanceEngine(calendar: calendar)
    let current = engine.period(containing: now, of: BudgetSnapshot(self))
    let sorted = carryoverChanges.sorted { $0.effectiveAt < $1.effectiveAt }
    let applied = sorted.filter { $0.effectiveAt <= current.start }
    let pending = sorted.filter { $0.effectiveAt > current.start }
    let inEffect = applied.last?.enabled ?? pending.first?.previousEnabled ?? previousSetting

    let kept = carryoverEnabled != inEffect ? pending.first : nil
    for change in pending where change !== kept {
      carryoverChanges.removeAll { $0 === change }
      modelContext?.delete(change)
    }
    guard carryoverEnabled != inEffect else { return }

    if let kept {
      kept.enabled = carryoverEnabled
      kept.previousEnabled = inEffect
      kept.effectiveAt = current.end
    } else {
      let change = CarryoverChange(
        enabled: carryoverEnabled,
        previousEnabled: inEffect,
        effectiveAt: current.end
      )
      modelContext?.insert(change)
      carryoverChanges.append(change)
    }
  }

  // MARK: - Amount changes

  /// Records that the available amount was `previousCents` before today, so earlier days keep
  /// the allowance they had and the current amount applies from today. Call after changing
  /// spendable, bills, or savings.
  ///
  /// Nothing is recorded before the budget's first day, when no day has used the old amount. A
  /// second change on the same day keeps the amount from before today, and drops the record if
  /// the amount goes back to it.
  func recordAmountChange(from previousCents: Int, now: Date, calendar: Calendar) {
    let today = calendar.startOfDay(for: now)
    let engine = AllowanceEngine(calendar: calendar)
    guard today > engine.period(at: 0, of: BudgetSnapshot(self)).start else { return }
    let currentCents = availablePerPeriodCents
    if let existing = amountChanges.first(where: { $0.effectiveAt == today }) {
      guard existing.previousAvailableCents == currentCents else { return }
      amountChanges.removeAll { $0 === existing }
      modelContext?.delete(existing)
    } else if previousCents != currentCents {
      let change = AmountChange(previousAvailableCents: previousCents, effectiveAt: today)
      modelContext?.insert(change)
      amountChanges.append(change)
    }
  }

  // MARK: - Extra money

  /// Adds one-off money, like a bonus or gift, to the period containing `now`. It raises today's
  /// allowance and the period's remainder.
  @discardableResult
  func addExtraMoney(cents: Int, note: String, now: Date) -> ExtraMoney {
    let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
    let extra = ExtraMoney(amountCents: cents, note: note, date: now)
    modelContext?.insert(extra)
    extraMoney.append(extra)
    return extra
  }

  func removeExtraMoney(_ extra: ExtraMoney) {
    extraMoney.removeAll { $0 === extra }
    modelContext?.delete(extra)
  }

  /// Extra money dated in `period`, newest first.
  func extraMoneyItems(in period: BudgetPeriod) -> [ExtraMoney] {
    extraMoney.filter { period.contains($0.date) }.sorted { $0.date > $1.date }
  }

  // MARK: - Bills

  /// `bill`'s paid or skipped mark in `period`, if any.
  func payment(for bill: FixedBill, in period: BudgetPeriod) -> BillPayment? {
    billPayments.first { $0.bill === bill && period.contains($0.date) }
  }

  func status(of bill: FixedBill, in period: BudgetPeriod) -> BillStatus {
    guard let mark = payment(for: bill, in: period) else { return .unpaid }
    return mark.isSkipped ? .skipped : .paid(cents: mark.paidCents)
  }

  /// Marks `bill` paid or skipped in the period containing `now`, or clears its mark. From now
  /// on the period gets back what the bill doesn't use: all of it when skipped, the difference
  /// when paid at another amount. A new mark replaces the bill's earlier one in the period.
  func setStatus(_ status: BillStatus, of bill: FixedBill, now: Date, calendar: Calendar) {
    let engine = AllowanceEngine(calendar: calendar)
    let period = engine.period(containing: now, of: BudgetSnapshot(self))
    if let existing = payment(for: bill, in: period) {
      billPayments.removeAll { $0 === existing }
      modelContext?.delete(existing)
    }
    let paidCents: Int
    switch status {
    case .unpaid:
      return
    case .paid(let cents):
      paidCents = cents
    case .skipped:
      paidCents = 0
    }
    let mark = BillPayment(
      isSkipped: status == .skipped,
      plannedCents: bill.amountCents,
      paidCents: paidCents,
      date: now
    )
    modelContext?.insert(mark)
    billPayments.append(mark)
    mark.bill = bill
  }

  /// Keeps `bill`'s mark in `period` right after its amount drops by `releasedCents` (all of it
  /// when the bill is removed). The amount change already gives the period `releasedCents` from
  /// today, and a paid or skipped bill had settled its share, so the mark gives that much less.
  func rebaseMark(of bill: FixedBill, releasedCents: Int, in period: BudgetPeriod) {
    guard releasedCents != 0, let mark = payment(for: bill, in: period) else { return }
    mark.plannedCents -= releasedCents
  }

  // MARK: - Time zones

  /// Re-expresses the day-only dates (`periodStart` and every change's dates) as local midnights
  /// in `calendar`'s time zone, keeping their calendar days, so paydays and change dates stay on
  /// the same dates after the device moves to another time zone. A budget with no recorded time
  /// zone just records `calendar`'s. Returns whether anything changed.
  @discardableResult
  func adoptTimeZone(of calendar: Calendar) -> Bool {
    let identifier = calendar.timeZone.identifier
    guard identifier != timeZoneIdentifier else { return false }
    defer { timeZoneIdentifier = identifier }
    guard let previous = TimeZone(identifier: timeZoneIdentifier) else { return true }
    var source = calendar
    source.timeZone = previous
    func sameDay(_ date: Date) -> Date {
      let components = source.dateComponents([.year, .month, .day], from: date)
      guard let moved = calendar.date(from: components) else { return date }
      return calendar.startOfDay(for: moved)
    }
    periodStart = sameDay(periodStart)
    for change in carryoverChanges {
      change.effectiveAt = sameDay(change.effectiveAt)
    }
    for change in amountChanges {
      change.effectiveAt = sameDay(change.effectiveAt)
    }
    for change in scheduleChanges {
      change.effectiveAt = sameDay(change.effectiveAt)
      change.previousPeriodStart = sameDay(change.previousPeriodStart)
    }
    return true
  }
}

/// A fixed bill's state in one period.
enum BillStatus: Equatable, Sendable {
  case unpaid
  case paid(cents: Int)
  case skipped
}
