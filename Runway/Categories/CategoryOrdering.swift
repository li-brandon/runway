import Foundation

/// Pure picker ordering, independent of SwiftData and SwiftUI.
enum CategoryOrdering {
  /// Up to three distinct recently used categories, then the remaining saved order.
  /// Equal dates keep saved order. Unknown category IDs are ignored; a nonpositive limit disables
  /// recents. Callers supply IDs in sortOrder and expense usage in any order.
  static func orderedIDs<ID: Hashable>(
    in sortOrder: [ID],
    usage: [(id: ID, date: Date)],
    recentLimit: Int = 3
  ) -> [ID] {
    var latest: [ID: Date] = [:]
    for entry in usage {
      latest[entry.id] = max(latest[entry.id] ?? entry.date, entry.date)
    }
    let recent = sortOrder.enumerated().filter { latest[$0.element] != nil }.sorted { lhs, rhs in
      let left = latest[lhs.element]!
      let right = latest[rhs.element]!
      return left == right ? lhs.offset < rhs.offset : left > right
    }
    let first = recent.prefix(max(0, recentLimit)).map(\.element)
    let used = Set(first)
    return first + sortOrder.filter { !used.contains($0) }
  }
}
