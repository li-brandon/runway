import Foundation
import SwiftData
import SwiftUI

struct ContentView: View {
  @Query(sort: \Expense.date, order: .reverse) private var expenses: [Expense]

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day())
          .font(.headline)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal)

        if expenses.isEmpty {
          ContentUnavailableView(
            "Nothing Logged Yet",
            systemImage: "dollarsign.circle",
            description: Text("Set up a budget to see how much you can spend today.")
          )
        } else {
          List(expenses) { expense in
            LabeledContent(
              expense.note.isEmpty ? "Expense" : expense.note,
              value: Money.format(cents: expense.amountCents)
            )
          }
        }
      }
      .navigationTitle("Runway")
    }
  }
}

#Preview {
  ContentView()
    .modelContainer(try! RunwayModelContainer.make(inMemory: true))
}
