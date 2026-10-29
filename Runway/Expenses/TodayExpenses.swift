import Foundation

/// Filters by the spending day and breaks equal spending dates by the logging time.
func todayExpenses(_ expenses: [Expense], now: Date, calendar: Calendar) -> [Expense] {
  expenses.filter { calendar.isDate($0.date, inSameDayAs: now) }.sorted {
    if $0.date == $1.date { return $0.createdAt > $1.createdAt }
    return $0.date > $1.date
  }
}
