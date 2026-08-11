import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Bulk-import tasks from a .csv or .xlsx file. Recognized columns: Task
/// (required), Notes, Shelf, Due Date, Next Step, Duration, Tags, Priority,
/// Date Added — matched case-insensitively, see ImportedTaskField for the
/// accepted aliases. Rows whose Shelf doesn't match an existing shelf land
/// on the chosen default — a real shelf, or Inbox (the default) for plain
/// capture-and-sort-later entries.
struct ImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Shelf.sortOrder) private var shelves: [Shelf]

    /// nil means "Inbox" — the default.
    @State private var defaultShelf: Shelf?
    @State private var isShowingFilePicker = false
    @State private var summary: TaskImportSummary?
    @State private var errorMessage: String?
    @State private var isImporting = false

    private let supportedTypes: [UTType] = [
        .commaSeparatedText,
        UTType(filenameExtension: "xlsx") ?? .data
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Task (required), Notes, Shelf, Due Date, Next Step, Duration, Tags, Priority, Date Added")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Recognized Columns")
                } footer: {
                    Text("Tags can be separated by commas or semicolons. Rows whose Shelf doesn't match an existing shelf use the default below.")
                }

                Section {
                    Picker("Default Shelf", selection: $defaultShelf) {
                        Text("Inbox").tag(nil as Shelf?)
                        ForEach(shelves) { shelf in
                            Text(shelf.name).tag(shelf as Shelf?)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.inline)
                } header: {
                    Text("Default Shelf")
                } footer: {
                    Text("Inbox keeps just the title for sorting later; a shelf keeps every column.")
                }

                Section {
                    Button {
                        isShowingFilePicker = true
                    } label: {
                        if isImporting {
                            ProgressView()
                        } else {
                            Label("Choose File...", systemImage: "square.and.arrow.down")
                        }
                    }
                    .disabled(isImporting)
                }

                if let summary {
                    Section("Result") {
                        Text("Imported \(summary.importedCount) task\(summary.importedCount == 1 ? "" : "s").")
                        ForEach(summary.errors, id: \.self) { error in
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Import Tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(isPresented: $isShowingFilePicker, allowedContentTypes: supportedTypes) { result in
                handlePickedFile(result)
            }
        }
    }

    private func handlePickedFile(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
        case .success(let url):
            errorMessage = nil
            summary = nil
            isImporting = true

            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }

            do {
                summary = try TaskImportService.importTasks(
                    from: url,
                    defaultShelf: defaultShelf,
                    allShelves: shelves,
                    modelContext: modelContext
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            isImporting = false
        }
    }
}

#Preview {
    ImportView()
        .modelContainer(for: [TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, Tag.self, NamedSchedule.self, Habit.self, HabitLog.self], inMemory: true)
}
