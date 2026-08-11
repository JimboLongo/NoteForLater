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
    @Query private var allTasks: [TaskItem]
    @Query private var allScheduledBlocks: [ScheduledBlock]
    @Query private var allShelves: [Shelf]
    @Query private var allTags: [Tag]
    @Query private var allHabits: [Habit]
    @Query private var allTaskCompletionRecords: [TaskCompletionRecord]

    private var accountService: GoogleAccountService { GoogleAccountService.shared }
    private var locationService: LocationMonitoringService { LocationMonitoringService.shared }
    private var nightlyReviewSettings: NightlyReviewSettings { NightlyReviewSettings.shared }
    private var upcomingReminderSettings: UpcomingReminderSettings { UpcomingReminderSettings.shared }

    @State private var isSigningIn = false
    @State private var isSyncingCalendars = false
    @State private var errorMessage: String?
    @State private var isShowingClearAllConfirmation = false
    @State private var isShowingClearHabitsConfirmation = false
    @State private var isShowingResetTaskStatsConfirmation = false
    @State private var isShowingCannotDisableMealPlanningAlert = false

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
            } header: {
                Text("Location Reminders")
            } footer: {
                Text("Attach a place to any tag from the Tags tab and you'll get a notification listing tagged tasks whenever you come within range.")
            }

            Section {
                Toggle("Meal Planning", isOn: mealPlanningBinding)
            } footer: {
                Text("Adds a Pantry shelf for tracking ingredients on hand. Pantry is never a destination for Inbox items — add to it directly, or import from a grocery receipt photo.")
            }

            Section {
                Toggle("Nightly Review", isOn: nightlyReviewEnabledBinding)
                if nightlyReviewSettings.isEnabled {
                    DatePicker("Time", selection: nightlyReviewTimeBinding, displayedComponents: [.hourAndMinute])
                }
            } header: {
                Text("Nightly Review")
            } footer: {
                Text("Each night at this time, you'll get a reminder to mark today's schedule complete or not, sort what's landed in your Inbox, and generate and approve tomorrow's schedule. Start one any time from the bottom of the More tab.")
            }

            Section {
                Toggle("Remind Me Before Events", isOn: upcomingReminderEnabledBinding)
                if upcomingReminderSettings.isEnabled {
                    Picker("Notice", selection: upcomingReminderLeadBinding) {
                        ForEach(UpcomingReminderSettings.leadOptions, id: \.self) { minutes in
                            Text(UpcomingReminderSettings.leadLabel(for: minutes)).tag(minutes)
                        }
                    }
                }
            } header: {
                Text("Upcoming Reminders")
            } footer: {
                Text("Get a push notification this far before each approved task or habit on your calendar is about to start.")
            }

            Section {
                Button("Reset Task Stats", role: .destructive) {
                    isShowingResetTaskStatsConfirmation = true
                }
                Button("Delete All Habits", role: .destructive) {
                    isShowingClearHabitsConfirmation = true
                }
                Button("Clear All Data", role: .destructive) {
                    isShowingClearAllConfirmation = true
                }
            } header: {
                Text("Danger Zone")
            } footer: {
                Text("\"Reset Task Stats\" clears every completion snapshot behind the Task Stats page — completed tasks and habits themselves are untouched. \"Delete All Habits\" removes every habit and its tracked days (and cancels their reminders). \"Clear All Data\" additionally deletes every inbox item, task, shelf, scheduled block, and tag on this device, and disconnects your Google account. None of this can be undone.")
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
            "Reset Task Stats?",
            isPresented: $isShowingResetTaskStatsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset Task Stats", role: .destructive, action: resetTaskStats)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes every completion snapshot behind the Task Stats page. This can't be undone.")
        }
        .confirmationDialog(
            "Delete all habits?",
            isPresented: $isShowingClearHabitsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete All Habits", role: .destructive, action: clearAllHabits)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes every habit and its tracked days on this device. This can't be undone.")
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
        .alert("Can't Turn Off Meal Planning", isPresented: $isShowingCannotDisableMealPlanningAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Delete the items on your Pantry shelf first.")
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

    /// Reads/writes Meal Planning as pure derived state — "on" means a
    /// Pantry shelf exists, "off" means it doesn't — rather than a separate
    /// flag that could drift out of sync with the shelf actually being
    /// there. Mirrors ShelvesView's own add/delete-shelf pattern.
    private var mealPlanningBinding: Binding<Bool> {
        Binding(
            get: { allShelves.contains { $0.isPantry } },
            set: { isOn in
                if isOn {
                    enableMealPlanning()
                } else {
                    disableMealPlanning()
                }
            }
        )
    }

    private func enableMealPlanning() {
        guard !allShelves.contains(where: { $0.isPantry }) else { return }
        let nextOrder = (allShelves.map(\.sortOrder).max() ?? -1) + 1
        let pantry = Shelf(name: "Pantry", systemImage: "refrigerator", sortOrder: nextOrder)
        pantry.isPantry = true
        pantry.tracksDuration = false
        pantry.hasDueDates = false
        pantry.hasNextStep = false
        pantry.hasPriority = false
        modelContext.insert(pantry)
    }

    /// Same guard ShelvesView uses for manual shelf deletion — don't
    /// silently drop a shelf's contents; make the user clear it first.
    private func disableMealPlanning() {
        guard let pantry = allShelves.first(where: { $0.isPantry }) else { return }
        if let tasks = pantry.tasks, !tasks.isEmpty {
            isShowingCannotDisableMealPlanningAlert = true
            return
        }
        modelContext.delete(pantry)
    }

    private var nightlyReviewEnabledBinding: Binding<Bool> {
        Binding(
            get: { nightlyReviewSettings.isEnabled },
            set: { isOn in
                nightlyReviewSettings.isEnabled = isOn
                if isOn { NightlyReviewNotificationService.shared.requestAuthorization() }
            }
        )
    }

    private var nightlyReviewTimeBinding: Binding<Date> {
        Binding(
            get: { nightlyReviewSettings.time },
            set: { nightlyReviewSettings.time = $0 }
        )
    }

    private var upcomingReminderEnabledBinding: Binding<Bool> {
        Binding(
            get: { upcomingReminderSettings.isEnabled },
            set: { isOn in
                upcomingReminderSettings.isEnabled = isOn
                if isOn { UpcomingBlockNotificationService.shared.requestAuthorization() }
            }
        )
    }

    private var upcomingReminderLeadBinding: Binding<Int> {
        Binding(
            get: { upcomingReminderSettings.leadMinutes },
            set: { upcomingReminderSettings.leadMinutes = $0 }
        )
    }

    private func resetTaskStats() {
        for record in allTaskCompletionRecords {
            modelContext.delete(record)
        }
        // Most Pushed Task (and every other pushed-count stat) is read
        // straight off TaskItem/TaskCompletionRecord.pushedCount, not its
        // own record — a reset that only cleared completion snapshots
        // would leave old push counts sitting on still-active shelf tasks.
        for task in allTasks {
            task.pushedCount = 0
        }
    }

    private func clearAllHabits() {
        for habit in allHabits {
            HabitNotificationService.shared.cancelAll(for: habit)
            modelContext.delete(habit)
        }
    }

    private func clearAllData() {
        for task in allTasks { modelContext.delete(task) }
        for block in allScheduledBlocks { modelContext.delete(block) }
        for shelf in allShelves { modelContext.delete(shelf) }
        for tag in allTags { modelContext.delete(tag) }
        for window in eligibleHoursWindows { modelContext.delete(window) }
        for subscription in subscriptions { modelContext.delete(subscription) }
        clearAllHabits()
        accountService.signOut()
        locationService.syncRegions(with: [])
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
    .modelContainer(for: [TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, Tag.self, NamedSchedule.self, Habit.self, HabitLog.self, TaskCompletionRecord.self], inMemory: true)
}
