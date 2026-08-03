import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Bulk-import habits from a .csv or .xlsx file. Recognized columns: Name
/// (required), Start Date, Times Per Day, Days, Reminder Times — matched
/// case-insensitively, see ImportedHabitField for the accepted aliases.
/// Anything not recognized falls back to the same defaults a new habit
/// starts with in HabitEditView.
struct HabitImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Habit.sortOrder) private var habits: [Habit]

    @State private var isShowingFilePicker = false
    @State private var summary: HabitImportSummary?
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
                    Text("Name (required), Start Date, Times Per Day, Days, Reminder Times")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Recognized Columns")
                } footer: {
                    Text("Days accepts names like \"Mon, Wed, Fri\" or the words Daily/Weekdays/Weekends. Reminder Times accepts a comma-separated list like \"8:00 AM, 6:00 PM\" — missing or extra reminders are padded or trimmed to match Times Per Day.")
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
                        Text("Imported \(summary.importedCount) habit\(summary.importedCount == 1 ? "" : "s").")
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
            .navigationTitle("Import Habits")
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
                let nextOrder = (habits.map(\.sortOrder).max() ?? -1) + 1
                summary = try HabitImportService.importHabits(
                    from: url,
                    modelContext: modelContext,
                    startingSortOrder: nextOrder
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            isImporting = false
        }
    }
}

#Preview {
    HabitImportView()
        .modelContainer(for: [InboxItem.self, TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, Tag.self, NamedSchedule.self, Habit.self, HabitLog.self], inMemory: true)
}
