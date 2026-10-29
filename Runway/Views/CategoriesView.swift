import Foundation
import SwiftData
import SwiftUI

struct CategoriesView: View {
  @Environment(\.modelContext) private var modelContext
  @Query(sort: [SortDescriptor(\Category.sortOrder), SortDescriptor(\Category.name)])
  private var categories: [Category]
  @State private var editor: CategoryEditorRequest?
  @State private var deleting: Category?
  @State private var showsDelete = false
  @State private var errorMessage = ""
  @State private var showsError = false

  var body: some View {
    List {
      Section {
        ForEach(categories) { category in
          Button {
            editor = CategoryEditorRequest(category: category)
          } label: {
            CategoryLabel(category: category)
          }
          .tint(.primary)
          .swipeActions {
            if !category.isSystem {
              Button("Delete", role: .destructive) {
                deleting = category
                showsDelete = true
              }
            }
          }
        }
        .onMove { offsets, destination in
          perform {
            try CategoryService(context: modelContext).move(from: offsets, to: destination)
          }
        }
      } footer: {
        Text("Tap to edit. Use Edit to reorder. Other cannot be renamed or deleted.")
      }
    }
    .navigationTitle("Categories")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("Add Category", systemImage: "plus") {
          editor = CategoryEditorRequest(category: nil)
        }
      }
      ToolbarItem(placement: .primaryAction) {
        EditButton()
      }
    }
    .sheet(item: $editor) { request in
      NavigationStack {
        CategoryEditor(category: request.category)
      }
    }
    .confirmationDialog(
      "Delete category?",
      isPresented: $showsDelete,
      titleVisibility: .visible,
      presenting: deleting
    ) { category in
      Button("Delete Category", role: .destructive) {
        perform {
          try CategoryService(context: modelContext).delete(category)
        }
        deleting = nil
      }
      Button("Cancel", role: .cancel) {
        deleting = nil
      }
    } message: { category in
      Text("Delete \(category.name)? \(category.expenses.count) expenses will move to Other.")
    }
    .alert("Couldn't Save Categories", isPresented: $showsError) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(errorMessage)
    }
  }

  private func perform(_ operation: () throws -> Void) {
    do {
      try operation()
      try modelContext.save()
    } catch {
      modelContext.rollback()
      errorMessage = error.localizedDescription
      showsError = true
    }
  }
}

private struct CategoryEditorRequest: Identifiable {
  let id = UUID()
  let category: Category?
}

private struct CategoryEditor: View {
  let category: Category?

  @Environment(\.modelContext) private var modelContext
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var symbol: String
  @State private var colorHex: String
  @State private var errorMessage: String?

  init(category: Category?) {
    self.category = category
    _name = State(initialValue: category?.name ?? "")
    _symbol = State(initialValue: category?.symbol ?? "tag")
    _colorHex = State(initialValue: category?.colorHex ?? CategoryService.colors[0])
  }

  var body: some View {
    Form {
      Section {
        TextField("Name", text: $name)
          .disabled(category?.isSystem == true)
        Picker("Color", selection: $colorHex) {
          ForEach(CategoryService.colors, id: \.self) { hex in
            Label(CategoryAppearance.colorName(hex), systemImage: "circle.fill")
              .foregroundStyle(CategoryAppearance.color(hex))
              .tag(hex)
          }
        }
        Picker("Symbol", selection: $symbol) {
          ForEach(CategoryService.symbols, id: \.self) { symbol in
            Label(CategoryAppearance.symbolName(symbol), systemImage: symbol)
              .tag(symbol)
          }
        }
        Label(name.isEmpty ? "Category" : name, systemImage: symbol)
          .foregroundStyle(CategoryAppearance.color(colorHex))
      } footer: {
        if category?.isSystem == true {
          Text("Other is the default for expenses. It cannot be renamed or deleted.")
        }
      }
      if let errorMessage {
        Section {
          Text(errorMessage)
            .foregroundStyle(.red)
        }
      }
    }
    .navigationTitle(category == nil ? "Add Category" : "Edit Category")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") {
          dismiss()
        }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save", action: save)
      }
    }
  }

  private func save() {
    let service = CategoryService(context: modelContext)
    do {
      if let category {
        try service.update(category, name: name, symbol: symbol, colorHex: colorHex)
      } else {
        try service.add(name: name, symbol: symbol, colorHex: colorHex)
      }
      try modelContext.save()
      dismiss()
    } catch {
      modelContext.rollback()
      errorMessage = error.localizedDescription
    }
  }
}

struct CategoryLabel: View {
  let category: Category

  var body: some View {
    Label {
      Text(category.name)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: category.symbol)
        .foregroundStyle(CategoryAppearance.color(category.colorHex))
        .accessibilityHidden(true)
    }
  }
}

enum CategoryAppearance {
  static func color(_ hex: String) -> Color {
    let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16)
      ?? 0x8E8E93
    return Color(
      .sRGB,
      red: Double((value >> 16) & 0xFF) / 255,
      green: Double((value >> 8) & 0xFF) / 255,
      blue: Double(value & 0xFF) / 255,
      opacity: 1
    )
  }

  static func colorName(_ hex: String) -> String {
    switch hex {
    case "#FF9500": "Orange"
    case "#34C759": "Green"
    case "#007AFF": "Blue"
    case "#AF52DE": "Purple"
    case "#FF2D55": "Pink"
    case "#00C7BE": "Teal"
    default: "Gray"
    }
  }

  static func symbolName(_ symbol: String) -> String {
    switch symbol {
    case "fork.knife": "Food"
    case "cart": "Cart"
    case "car": "Car"
    case "bag": "Bag"
    case "film": "Film"
    case "doc.text": "Document"
    case "heart": "Heart"
    case "house": "House"
    case "airplane": "Airplane"
    default: "Tag"
    }
  }
}
