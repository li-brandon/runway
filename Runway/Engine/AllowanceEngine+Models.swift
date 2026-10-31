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
      let cents = payment.adjustmentCents
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
  /// allowance and the period's remainder. Dated today's local midnight, like every day-only date.
  @discardableResult
  func addExtraMoney(cents: Int, note: String, now: Date, calendar: Calendar) -> ExtraMoney {
    let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
    let extra = ExtraMoney(amountCents: cents, note: note, date: calendar.startOfDay(for: now))
    modelContext?.insert(extra)
    extraMoney.append(extra)
    return extra
  }

  func removeExtraMoney(_ extra: ExtraMoney) {
    extraMoney.removeAll { $0 === extra }
    modelContext?.delete(extra)
  }

  /// Extra money dated in `period`, newest day first.
  func extraMoneyItems(in period: BudgetPeriod) -> [ExtraMoney] {
    extraMoney.filter { period.contains($0.date) }.sorted { $0.date > $1.date }
  }

  // MARK: - Bills

  /// `bill`'s paid or skipped mark in `period`, if any.
  func payment(for bill: FixedBill, in period: BudgetPeriod) -> BillPayment? {
    billPayments.filter { $0.bill === bill && period.contains($0.date) }
      .max { $0.sequence < $1.sequence }
  }

  func status(of bill: FixedBill, in period: BudgetPeriod) -> BillStatus {
    guard let mark = payment(for: bill, in: period), !mark.isCleared else { return .unpaid }
    return mark.isSkipped ? .skipped : .paid(cents: mark.paidCents)
  }

  /// Appends a dated adjustment so replacing or clearing a mark preserves earlier days.
  func setStatus(_ status: BillStatus, of bill: FixedBill, now: Date, calendar: Calendar) {
    let engine = AllowanceEngine(calendar: calendar)
    let period = engine.period(containing: now, of: BudgetSnapshot(self))
    guard self.status(of: bill, in: period) != status else { return }
    let previous = payment(for: bill, in: period)
    let previousCredit = previous.map { $0.isCleared ? 0 : $0.plannedCents - $0.paidCents } ?? 0
    let paidCents: Int
    switch status {
    case .unpaid, .skipped:
      paidCents = 0
    case .paid(let cents):
      paidCents = cents
    }
    let credit = status == .unpaid ? 0 : bill.amountCents - paidCents
    appendMark(
      of: bill,
      status: status,
      plannedCents: bill.amountCents,
      paidCents: paidCents,
      adjustmentCents: credit - previousCredit,
      date: calendar.startOfDay(for: now)
    )
  }

  private func appendMark(
    of bill: FixedBill,
    status: BillStatus,
    plannedCents: Int,
    paidCents: Int,
    adjustmentCents: Int,
    date: Date
  ) {
    let sequence = (billPayments.map(\.sequence).max() ?? 0) + 1
    let mark = BillPayment(
      isSkipped: status == .skipped,
      isCleared: status == .unpaid,
      plannedCents: plannedCents,
      paidCents: paidCents,
      adjustmentCents: adjustmentCents,
      sequence: sequence,
      date: date
    )
    modelContext?.insert(mark)
    billPayments.append(mark)
    mark.bill = bill
  }

  func removeBillPayment(_ mark: BillPayment) {
    billPayments.removeAll { $0 === mark }
    modelContext?.delete(mark)
  }

  /// Sets the adjustments of `bill`'s marks around `date` as `setStatus` would have, each one the
  /// change from the mark before it, so they add up to the latest mark's credit. Call after editing
  /// or removing a mark. Covers the period containing `date`, or if `date` is before the budget's
  /// start, every mark before it, as they could all land in one period if the start moves earlier.
  func rechainMarks(of bill: FixedBill, around date: Date, calendar: Calendar) {
    let engine = AllowanceEngine(calendar: calendar)
    let period = engine.period(containing: date, of: BudgetSnapshot(self))
    let isBeforeStart = date < period.start
    let marks = billPayments.filter { mark in
      guard mark.bill === bill else { return false }
      return isBeforeStart ? mark.date < period.start : period.contains(mark.date)
    }
    var previousCredit = 0
    for mark in marks.sorted(by: { $0.sequence < $1.sequence }) {
      mark.adjustmentCents = mark.creditCents - previousCredit
      previousCredit = mark.creditCents
    }
  }

  /// Offsets the amount edit for an already settled bill, from the edit day forward.
  func rebaseMark(
    of bill: FixedBill,
    releasedCents: Int,
    in period: BudgetPeriod,
    now: Date,
    calendar: Calendar
  ) {
    guard releasedCents != 0,
      let mark = payment(for: bill, in: period), !mark.isCleared
    else { return }
    appendMark(
      of: bill,
      status: status(of: bill, in: period),
      plannedCents: mark.plannedCents - releasedCents,
      paidCents: mark.paidCents,
      adjustmentCents: -releasedCents,
      date: calendar.startOfDay(for: now)
    )
  }

  // MARK: - Time zones

  /// Re-expresses the day-only dates (`periodStart`, every change's dates, extra money, and bill
  /// marks) as local midnights in `calendar`'s time zone, keeping their calendar days, so they
  /// stay on the same dates after the device moves to another time zone. Expenses keep their
  /// instants. A budget with no recorded time zone just records `calendar`'s. Returns whether
  /// anything changed.
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
    for extra in extraMoney {
      extra.date = sameDay(extra.date)
    }
    for payment in billPayments {
      payment.date = sameDay(payment.date)
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
