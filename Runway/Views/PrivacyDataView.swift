import Foundation
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

extension EnvironmentValues {
  /// Call straight after replacing or erasing the store, in the same update. The root rebuilds its
  /// views, so none of them, including this settings screen, read a deleted model.
  @Entry var dataDidReplace: @MainActor () -> Void = {}
}

/// The app lock, and exporting, importing, and erasing data. The logic lives in `Runway/Privacy`.
struct PrivacyDataView: View {
  let screenshotScenario: ScreenshotScenario?

  @Environment(\.modelContext) private var modelContext
  @Environment(AppLockController.self) private var lock
  @Environment(\.dataDidReplace) private var dataDidReplace
  @State private var lockIsOn = false
  @State private var jsonExport: JSONExportFile?
  @State private var csvExport: CSVExportFile?
  @State private var showsImporter = false
  /// Set while the confirm dialog for a checked backup is open.
  @State private var pendingImport: ValidatedImport?
  @State private var showsResetConfirmation = false
  @State private var errorMessage: String?

  init(screenshotScenario: ScreenshotScenario? = nil) {
    self.screenshotScenario = screenshotScenario
  }

  var body: some View {
    Form {
      Section {
        Toggle("Lock with Face ID or Passcode", isOn: $lockIsOn)
        if let message = lock.message {
          Text(message)
            .font(.footnote)
            .foregroundStyle(.red)
        }
      } header: {
        Text("Privacy")
      } footer: {
        Text("Asks for it when you return to Runway, and hides Runway in the app switcher.")
      }

      Section {
        if let jsonExport {
          ShareLink(item: jsonExport, preview: SharePreview(jsonExport.fileName)) {
            Label("Export All Data (JSON)", systemImage: "square.and.arrow.up")
          }
        }
        if let csvExport {
          ShareLink(item: csvExport, preview: SharePreview(csvExport.fileName)) {
            Label("Export Expenses (CSV)", systemImage: "tablecells")
          }
        }
        Button("Import from JSON Backup", systemImage: "square.and.arrow.down") {
          showsImporter = true
        }
      } header: {
        Text("Your data")
      } footer: {
        Text("Exports aren't encrypted, so keep them safe. Importing replaces all your data.")
      }

      Section {
        Button("Reset All Data", systemImage: "trash", role: .destructive) {
          showsResetConfirmation = true
        }
      } footer: {
        Text("Erases your budget, bills, expenses, and categories from this iPhone.")
      }
    }
    .navigationTitle("Privacy & Data")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      lockIsOn = lock.isEnabled
      refreshExports()
    }
    .onChange(of: lockIsOn) { _, isOn in
      Task {
        await lock.setEnabled(isOn)
        // Flips the switch back if the lock didn't turn on.
        lockIsOn = lock.isEnabled
      }
    }
    .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.json]) { result in
      readBackup(result)
    }
    .confirmationDialog(
      "Replace All Data?",
      isPresented: showsImportConfirmation,
      titleVisibility: .visible,
      presenting: pendingImport
    ) { validated in
      Button("Replace All Data", role: .destructive) {
        applyImport(validated)
      }
      Button("Cancel", role: .cancel) {}
    } message: { validated in
      Text(importMessage(validated.snapshot))
    }
    .confirmationDialog(
      "Reset All Data?",
      isPresented: $showsResetConfirmation,
      titleVisibility: .visible
    ) {
      Button("Reset All Data", role: .destructive, action: reset)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This erases everything in Runway from this iPhone and can't be undone.")
    }
    .alert("Something Went Wrong", isPresented: showsError) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(errorMessage ?? "")
    }
    .task {
      let opensReset = screenshotScenario == .privacyResetConfirm
      guard opensReset || screenshotScenario == .privacyImportConfirm else { return }
      // Let the screen settle before opening the dialog.
      do {
        try await Task.sleep(for: .milliseconds(600))
      } catch {
        return
      }
      if opensReset {
        showsResetConfirmation = true
      } else {
        // Offers the sample data's own export, so no file picker is involved.
        pendingImport = try? DataImport.validate(DataExport.snapshot(of: modelContext))
      }
    }
  }

  private var showsImportConfirmation: Binding<Bool> {
    Binding(
      get: { pendingImport != nil },
      set: { if !$0 { pendingImport = nil } }
    )
  }

  private var showsError: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )
  }

  private func importMessage(_ snapshot: RunwaySnapshot) -> String {
    let date = snapshot.exportedAt.formatted(date: .abbreviated, time: .shortened)
    let budgets = countText(snapshot.budgets.count, noun: "budget")
    let expenses = countText(snapshot.expenses.count, noun: "expense")
    return "Everything in Runway will be replaced by this backup from \(date), with \(budgets) and "
      + "\(expenses). This can't be undone."
  }

  private func countText(_ count: Int, noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
  }

  /// Files are built when the screen appears, since nothing can change the data while it's open.
  private func refreshExports() {
    let now = Date.now
    do {
      let snapshot = try DataExport.snapshot(of: modelContext, now: now)
      jsonExport = JSONExportFile(data: try DataExport.jsonData(from: snapshot), date: now)
      csvExport = CSVExportFile(text: try DataExport.expensesCSV(in: modelContext), date: now)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func readBackup(_ result: Result<URL, any Error>) {
    do {
      let url = try result.get()
      let isScoped = url.startAccessingSecurityScopedResource()
      defer {
        if isScoped { url.stopAccessingSecurityScopedResource() }
      }
      pendingImport = try DataImport.validate(Data(contentsOf: url))
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func applyImport(_ validated: ValidatedImport) {
    do {
      try DataImport.apply(validated, to: modelContext)
      dataDidReplace()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func reset() {
    do {
      try DataReset.reset(in: modelContext)
      dataDidReplace()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

#Preview {
  NavigationStack {
    PrivacyDataView()
  }
  .modelContainer(try! RunwayModelContainer.make(inMemory: true))
  .environment(
    AppLockController(authenticator: NoPromptAuthenticator(), isEnabled: true, isLocked: false)
  )
}
