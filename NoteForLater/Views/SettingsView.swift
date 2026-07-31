import SwiftUI
import SwiftData

/// App-wide settings. Currently just the Scheduler section: link a Google
/// account and choose which of its calendars count as "busy" so the AI
/// Scheduler doesn't propose blocks over existing events. The same sign-in
/// also grants Gmail read access, used by the Inbox tab's "Sync Unread
/// Gmail" action.
struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var subscriptions: [CalendarSubscription]

    private var accountService: GoogleAccountService { GoogleAccountService.shared }

    @State private var isSigningIn = false
    @State private var isSyncingCalendars = false
    @State private var errorMessage: String?

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
}

#Preview {
    NavigationStack {
        SettingsView()
    }
    .modelContainer(for: [InboxItem.self, TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self], inMemory: true)
}
