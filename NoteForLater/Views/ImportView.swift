import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Bulk-import tasks from a .csv or .xlsx file. Recognized columns: Title
/// (required), Notes, Shelf, Due Date, Next Step, Duration, Tags, Priority,
/// Date Added — matched case-insensitively, see ImportedTaskField for the
/// accepted aliases. Rows whose Shelf doesn't match an existing shelf land
/// on the chosen default shelf instead, so no attributes are ever dropped.
struct ImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Shelf.sortOrder) private var shelves: [Shelf]

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
                    Text("Title (required), Notes, Shelf, Due Date, Next Step, Duration, Tags, Priority, Date Added")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Recognized Columns")
                } footer: {
                    Text("Tags can be separated by commas or semicolons. Rows whose Shelf doesn't match an existing shelf use the default shelf below.")
                }

                Section("Default Shelf") {
                    if shelves.isEmpty {
                        Text("Add a shelf first from the More tab.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Default Shelf", selection: $defaultShelf) {
                            ForEach(shelves) { shelf in
                                Text(shelf.name).tag(shelf as Shelf?)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.inline)
                    }
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
                    .disabled(defaultShelf == nil || isImporting)
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
            .onAppear {
                if defaultShelf == nil { defaultShelf = shelves.first }
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
            guard let defaultShelf else { return }
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
        .modelContainer(for: [InboxItem.self, TaskItem.self, ScheduledBlock.self, Shelf.self], inMemory: true)
}
