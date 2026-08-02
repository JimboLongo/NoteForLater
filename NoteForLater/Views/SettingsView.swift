import SwiftUI
import SwiftData
import CoreLocation

/// App-wide settings. Currently just the Scheduler section: link a Google
/// account and choose which of its calendars count as "busy" so the AI
/// Scheduler doesn't propose blocks over existing events. The same sign-in
/// also grants Gmail read access, used by the Inbox tab's "Sync Unread
/// Gmail" action.
struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var subscriptions: [CalendarSubscription]
    @Query(sort: \EligibleHoursWindow.sortOrder) private var eligibleHoursWindows: [EligibleHoursWindow]
    @Query private var allInboxItems: [InboxItem]
    @Query private var allTasks: [TaskItem]
    @Query private var allScheduledBlocks: [ScheduledBlock]
    @Query private var allShelves: [Shelf]
    @Query private var allTags: [Tag]

    private var accountService: GoogleAccountService { GoogleAccountService.shared }
    private var locationService: LocationMonitoringService { LocationMonitoringService.shared }

    @State private var isSigningIn = false
    @State private var isSyncingCalendars = false
    @State private var errorMessage: String?
    @State private var isShowingClearAllConfirmation = false

    var body: some View {
        Form {
            Section("Google Account") {
                if let account = accountService.currentAccount {
                    LabeledContent("Signed in as", value: account.email)
                    Button("Disconnect", role: .destructive) {
                        accountService.signOut()
                        clearSubscriptions()
                    }
                } else {
                    Button {
                        signIn()
                    } label: {
                        if isSigningIn {
                            ProgressView()
                        } else {
                            Label("Connect Google Account", systemImage: "calendar.badge.plus")
                        }
                    }
                    .disabled(isSigningIn || !GoogleOAuthConfig.isConfigured)

                    if !GoogleOAuthConfig.isConfigured {
                        Text("Add your Client ID in GoogleOAuthConfig.swift to enable sign-in.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if accountService.currentAccount != nil {
                Section {
                    if subscriptions.isEmpty {
                        Text(isSyncingCalendars ? "Loading calendars…" : "No calendars synced yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(subscriptions.sorted { $0.name < $1.name }) { subscription in
                        Toggle(subscription.name, isOn: Binding(
                            get: { subscription.isEnabled },
                            set: { subscription.isEnabled = $0 }
                        ))
                    }

                    Button {
                        syncCalendars()
                    } label: {
                        if isSyncingCalendars {
                            ProgressView()
                        } else {
                            Label("Refresh Calendar List", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(isSyncingCalendars)
                } header: {
                    Text("Calendars to Check")
                } footer: {
                    Text("The AI Scheduler treats events on enabled calendars as busy and won't propose a task over them.")
                }
            }

            Section {
                if eligibleHoursWindows.isEmpty {
                    Text("No restriction — the AI Scheduler can assign any hour a shelf's own rule allows.")
                        .foregroundStyle(.secondary)
                }
                ForEach(eligibleHoursWindows) { window in
                    NavigationLink {
                        EligibleHoursEditView(window: window)
                    } label: {
                        HStack {
                            Text(window.summary)
                            if !window.isEnabled {
                                Spacer()
                                Text("Disabled")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
                .onDelete(perform: deleteEligibleHours)

                Button {
                    addEligibleHoursWindow()
                } label: {
                    Label("Add Eligible Hours", systemImage: "plus.circle.fill")
                }
            } header: {
                Text("Scheduling Hours")
            } footer: {
                Text("A global guardrail on top of each shelf's own pull windows — e.g. \"never assign anything before 7am or after 10pm.\" Leave empty for no restriction.")
            }

            Section {
                if locationService.authorizationStatus == .notDetermined {
                    Button {
                        locationService.requestAuthorization()
                    } label: {
                        Label("Enable Location Reminders", systemImage: "location.circle.fill")
                    }
                } else if locationService.authorizationStatus == .denied || locationService.authorizationStatus == .restricted {
                    Text("Location access is off. Enable it for NoteForLater in Settings to get proximity reminders.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                NavigationLink {
                    TagsListView()
                } label: {
                    Label("Manage Tags", systemImage: "tag")
                }
            } header: {
                Text("Location Reminders")
            } footer: {
                Text("Attach a place to any tag in the tag box and you'll get a notification listing tagged tasks whenever you come within range.")
            }

            Section {
                Button("Clear All Data", role: .destructive) {
                    isShowingClearAllConfirmation = true
                }
            } header: {
                Text("Danger Zone")
            } footer: {
                Text("Permanently deletes every inbox item, task, shelf, scheduled block, and tag on this device, and disconnects your Google account. This can't be undone.")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Settings")
        .onAppear {
            if accountService.currentAccount != nil, subscriptions.isEmpty {
                syncCalendars()
            }
        }
        .confirmationDialog(
            "Clear all saved data?",
            isPresented: $isShowingClearAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All Data", role: .destructive, action: clearAllData)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes everything in NoteForLater on this device. This can't be undone.")
        }
    }

    private func signIn() {
        isSigningIn = true
        errorMessage = nil
        Task {
            do {
                _ = try await accountService.signIn()
                await syncCalendarsAsync()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSigningIn = false
        }
    }

    private func syncCalendars() {
        Task { await syncCalendarsAsync() }
    }

    @MainActor
    private func syncCalendarsAsync() async {
        isSyncingCalendars = true
        errorMessage = nil
        defer { isSyncingCalendars = false }

        do {
            let calendarService = GoogleCalendarService(accountService: accountService)
            let remoteCalendars = try await calendarService.fetchCalendarList()

            var existingByID = Dictionary(uniqueKeysWithValues: subscriptions.map { ($0.calendarID, $0) })
            for remote in remoteCalendars {
                if let existing = existingByID[remote.id] {
                    existing.name = remote.name
                    existingByID.removeValue(forKey: remote.id)
                } else {
                    modelContext.insert(CalendarSubscription(calendarID: remote.id, name: remote.name, isEnabled: remote.isPrimary))
                }
            }
            // Anything left in existingByID is a calendar that no longer exists remotely.
            for stale in existingByID.values {
                modelContext.delete(stale)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearSubscriptions() {
        for subscription in subscriptions {
            modelContext.delete(subscription)
        }
    }

    private func addEligibleHoursWindow() {
        let nextOrder = (eligibleHoursWindows.map(\.sortOrder).max() ?? -1) + 1
        modelContext.insert(EligibleHoursWindow(sortOrder: nextOrder))
    }

    private func deleteEligibleHours(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(eligibleHoursWindows[index])
        }
    }

    private func clearAllData() {
        for item in allInboxItems { modelContext.delete(item) }
        for task in allTasks { modelContext.delete(task) }
        for block in allScheduledBlocks { modelContext.delete(block) }
        for shelf in allShelves { modelContext.delete(shelf) }
        for tag in allTags { modelContext.delete(tag) }
        for window in eligibleHoursWindows { modelContext.delete(window) }
        for subscription in subscriptions { modelContext.delete(subscription) }
        accountService.signOut()
        locationService.syncRegions(with: [])
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
    .modelContainer(for: [InboxItem.self, TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, Tag.self], inMemory: true)
}
