import Foundation
import SwiftData
import SwiftUI

/// Embeddable list for a quick logging sheet. Selection returns one saved category to the caller.
struct CategoryPicker: View {
  let onSelect: (Category) -> Void

  @Query(sort: [SortDescriptor(\Category.sortOrder), SortDescriptor(\Category.name)])
  private var categories: [Category]
  @Query private var expenses: [Expense]

  private var ordered: [Category] {
    let usage = expenses.compactMap { expense -> (id: PersistentIdentifier, date: Date)? in
      guard let category = expense.category else { return nil }
      return (id: category.persistentModelID, date: expense.date)
    }
    let ids = CategoryOrdering.orderedIDs(in: categories.map(\.persistentModelID), usage: usage)
    let byID = Dictionary(uniqueKeysWithValues: categories.map { ($0.persistentModelID, $0) })
    return ids.compactMap { byID[$0] }
  }

  var body: some View {
    List {
      Section {
        ForEach(ordered) { category in
          Button {
            onSelect(category)
          } label: {
            CategoryLabel(category: category)
          }
        }
      } footer: {
        Text("Your three most recently used categories appear first.")
      }
    }
    .navigationTitle("Choose Category")
    .navigationBarTitleDisplayMode(.inline)
  }
}

/// Screenshot host until quick logging (LIB-432) supplies the real presentation.
struct CategoryPickerHost: View {
  @State private var showsPicker = true
  @State private var selection = "Other"

  var body: some View {
    VStack(spacing: 16) {
      Text("Category: \(selection)")
      Button("Choose Category") {
        showsPicker = true
      }
    }
    .sheet(isPresented: $showsPicker) {
      NavigationStack {
        CategoryPicker { category in
          selection = category.name
          showsPicker = false
        }
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
              showsPicker = false
            }
          }
        }
      }
    }
  }
}
