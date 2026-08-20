import SwiftUI
import SwiftData

/// Stats + calendar for one habit. Tap any applicable past-or-today day in
/// the calendar to cycle it through Yes (green) → No (red) → Excused
/// (greyed out, white X) → Yes again; excused days are shown but omitted
/// entirely from streak and % complete math.
struct HabitDetailView: View {
    @Bindable var habit: Habit
    @Environment(\.modelContext) private var modelContext
    @Query private var habitLogs: [HabitLog]
    /// A second, date-bounded query for just the trailing-30-day window —
    /// Rolling 30 / Misses Remaining only ever need these, so there's no
    /// reason to filter the full-history `habitLogs` in memory for them.
    @Query private var windowLogs: [HabitLog]
    @State private var displayedMonth: Date = .now
    // Frozen while this screen is open — recomputing the full history walk
    // on every tap (even the cheaper shared-pass version) was still enough
    // to make tapping feel laggy. Refreshed on appear, so it's accurate
    // each time you arrive here, but edits made *during* this visit don't
    // retrigger it until you leave and come back. Rolling 30 / Misses
    // Remaining follow the exact same rule — see `cachedRollingStats`.
    @State private var cachedStats: HabitStats?
    @State private var cachedRollingStats: HabitRollingStats?
    /// Same idle debounce `HabitsTodayView.displayedHabits` uses — a day
    /// cell's own color still updates the instant you tap it (`setDay`
    /// mutates the model directly), but this stats grid stays frozen
    /// until 3 seconds pass with no further edit anywhere, instead of
    /// recomputing a full history walk after every single tap.
    @State private var refreshCoordinator = HabitStatsRefreshCoordinator.shared

    private let calendar = Calendar.current

    init(habit: Habit) {
        self.habit = habit
        let habitID = habit.id
        _habitLogs = Query(filter: #Predicate<HabitLog> { $0.habit?.id == habitID })
        let calendar = Calendar.current
        let windowStart = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: .now)) ?? .now
        _windowLogs = Query(filter: #Predicate<HabitLog> { $0.habit?.id == habitID && $0.date >= windowStart })
    }

    @State private var isShowingEdit = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                statsGrid
                calendarSection
                editButton
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .navigationTitle(habit.name.isEmpty ? "Habit" : habit.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isShowingEdit) {
            NavigationStack {
                HabitEditView(habit: habit)
            }
        }
        .onAppear {
            deduplicateLogs()
            recomputeStats()
        }
        .onChange(of: refreshCoordinator.idleRefreshTick) { _, _ in
            recomputeStats()
        }
    }

    private func recomputeStats() {
        cachedStats = habit.stats(calendar: calendar, logs: habitLogs)

        let windowLogsByDay = habit.logsByDay(from: windowLogs, calendar: calendar)
        let rolling = computeHabitRollingStats(
            status: { day in habit.status(on: day, asOf: .now, calendar: calendar, logsByDay: windowLogsByDay) },
            schedule: { habit.isApplicable(on: $0, calendar: calendar) },
            creationDate: habit.startDate,
            today: .now,
            threshold: habit.missThreshold,
            calendar: calendar
        )
        cachedRollingStats = rolling
        if rolling.isRecordEligible {
            let candidate = HabitRollingRecord(completedDays: rolling.completedDays, scheduledDays: rolling.scheduledDays)
            habit.rolling30Record = nextHabitRolling30Record(current: habit.rolling30Record, candidate: candidate)
        }
    }

    /// Moved out of the toolbar and down to the bottom of the screen,
    /// blue and full-width but shallow ("skinnier and wider") so it reads
    /// as a prominent action bar rather than a tall button — and so the
    /// whole screen (stats + calendar + this) fits without scrolling.
    /// Presented as a sheet (its own NavigationStack, mirroring how
    /// HabitsView already presents this same HabitEditView for *creating*
    /// a habit) rather than pushed onto this screen's own stack — every
    /// push-based option (a NavigationLink, `.navigationDestination(for:)`,
    /// `.navigationDestination(isPresented:)`) either froze this whole
    /// screen or silently no-opped, confirmed by bisection down to this
    /// exact button. The two screens' `@Query`s (this one's `habitLogs`/
    /// `windowLogs`, HabitEditView's own) apparently can't coexist live in
    /// the same NavigationStack; a sheet gives HabitEditView a wholly
    /// separate one.
    private var editButton: some View {
        Button {
            isShowingEdit = true
        } label: {
            Text("Edit Habit")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.borderedProminent)
        .tint(.blue)
    }

    /// If the same date ever ended up with more than one HabitLog, merge
    /// them into a single log and delete the rest. Cheap, and safe to run
    /// every time this screen opens.
    ///
    /// **This is now a safety net, not the fix.** It was written when the
    /// cause was thought to be "the tap handler looks one up independently
    /// of what the calendar displays". The real cause is upstream and
    /// affects every write path: a freshly-inserted `HabitLog` is invisible
    /// through the `habit.logs` inverse relationship until a save lands, so
    /// any lookup that traverses that relationship misses its own pending
    /// insert and creates another. `Habit.logOrCreate` fixes that at the
    /// source by fetching instead of traversing. A read-site patch could
    /// never have been sufficient — it only ever fired when *this one
    /// screen* opened for *one* habit, which is why 9 of 11 habits still
    /// carried duplicates when this was measured.
    ///
    /// Merging is delegated to `HabitLogMerge.collapse` so this and the
    /// repair migration can never disagree. It previously unioned the three
    /// occurrence arrays itself, which left an index in two arrays at once
    /// — see `HabitLogMerge` for why that was wrong and what replaced it.
    private func deduplicateLogs() {
        let byDay = Dictionary(grouping: habitLogs) { calendar.startOfDay(for: $0.date) }
        for (_, logs) in byDay where logs.count > 1 {
            HabitLogMerge.collapse(logs, context: modelContext)
        }
    }

    private var statsGrid: some View {
        let stats = cachedStats ?? HabitStats(currentStreak: 0, maxStreak: 0, mtdPercent: nil, ltdPercent: nil)
        let rolling = cachedRollingStats ?? HabitRollingStats(
            scheduledDays: 0, completedDays: 0, rolling30: nil,
            allowedMisses: 0, missesInWindow: 0, missesRemaining: 0,
            recoveryDate: nil, isRecordEligible: false, dayOfThirty: 1
        )
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            StatTile(title: "Current Streak", value: stats.currentStreakDisplay, color: streakColor(stats.currentStreak))
            StatTile(title: "Max Streak", value: stats.maxStreakDisplay, color: streakColor(stats.maxStreak))
            StatTile(title: "MTD % Complete", value: stats.mtdPercentDisplay, color: .primary)
            StatTile(title: "LTD % Complete", value: stats.ltdPercentDisplay, color: .primary)
            StatTile(
                title: "Rolling 30",
                value: rolling.rolling30Display,
                subtitle: rolling.isRecordEligible ? (habit.rolling30Record?.display ?? "Record —") : "Day \(rolling.dayOfThirty) of 30",
                color: .primary
            )
            StatTile(
                title: "Misses Remaining",
                value: rolling.missesRemainingDisplay,
                subtitle: rolling.recoveryDate.map { "+1 on \(Self.recoveryDateFormatter.string(from: $0))" },
                color: rolling.missesRemaining == 0 ? .orange : .primary
            )
        }
    }

    private static let recoveryDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    private func streakColor(_ value: Int) -> Color {
        if value > 0 { return .green }
        if value < 0 { return .red }
        return .primary
    }

    private var calendarSection: some View {
        // Built once per render and threaded through every cell, rather
        // than each of the ~35-42 cells re-scanning the full log list.
        let logsByDay = habit.logsByDay(from: habitLogs, calendar: calendar)
        return VStack(spacing: 6) {
            HStack {
                Button {
                    changeMonth(by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                Spacer()
                Text(monthTitle)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    changeMonth(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 4) {
                ForEach(Array(calendar.veryShortWeekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(daysInGrid.enumerated()), id: \.offset) { _, day in
                    if let day {
                        dayCell(day, logsByDay: logsByDay)
                    } else {
                        Color.clear.frame(minHeight: 26)
                    }
                }
            }

            legend
        }
    }

    private var legend: some View {
        VStack(spacing: 2) {
            HStack(spacing: 16) {
                legendItem(color: .green, label: "Yes")
                legendItem(color: .red, label: "No")
                legendItem(color: .gray, label: "Excused")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Text("Blank days aren't on this habit's schedule (see Edit > Days) and can't be tapped.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color.opacity(0.5)).frame(width: 8, height: 8)
            Text(label)
        }
    }

    private func dayCell(_ date: Date, logsByDay: [Date: HabitLog]) -> some View {
        let isApplicable = habit.isApplicable(on: date, calendar: calendar)
        let isFuture = date > calendar.startOfDay(for: .now)
        let isBeforeStart = date < calendar.startOfDay(for: habit.startDate)
        let canTap = isApplicable && !isFuture && !isBeforeStart
        // nil = pending (today, not yet resolved) — same neutral color as a
        // day that isn't applicable/tappable, not colored like a real miss.
        let status = habit.status(on: date, calendar: calendar, logsByDay: logsByDay)

        return ZStack {
            if status == .excused {
                Image(systemName: "xmark")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
            } else if isApplicable {
                Text("\(calendar.component(.day, from: date))")
                    .font(.caption)
                    .foregroundStyle(canTap ? .primary : .secondary)
            }
            // Not-applicable days show no number at all — deliberately
            // blank, so it's clear they're outside this habit's schedule
            // rather than just another disabled state.
        }
        .frame(maxWidth: .infinity, minHeight: 26)
        .background(cellColor(status: status, isApplicable: isApplicable, canTap: canTap))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture {
            guard canTap else { return }
            cycleDay(date, logsByDay: logsByDay)
        }
    }

    private func cellColor(status: HabitCompletionStatus?, isApplicable: Bool, canTap: Bool) -> Color {
        guard isApplicable else { return Color.clear }
        guard canTap, let status else { return Color.secondary.opacity(0.15) }
        switch status {
        case .yes: return .green.opacity(0.35)
        case .no: return .red.opacity(0.2)
        case .excused: return .gray.opacity(0.55)
        }
    }

    private var daysInGrid: [Date?] {
        guard
            let monthInterval = calendar.dateInterval(of: .month, for: displayedMonth),
            let daysInMonth = calendar.range(of: .day, in: .month, for: displayedMonth)?.count
        else { return [] }

        let firstDay = monthInterval.start
        let leadingBlanks = calendar.component(.weekday, from: firstDay) - 1

        var result: [Date?] = Array(repeating: nil, count: leadingBlanks)
        for dayOffset in 0..<daysInMonth {
            if let date = calendar.date(byAdding: .day, value: dayOffset, to: firstDay) {
                result.append(date)
            }
        }
        return result
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: displayedMonth)
    }

    private func changeMonth(by value: Int) {
        displayedMonth = calendar.date(byAdding: .month, value: value, to: displayedMonth) ?? displayedMonth
    }

    /// Yes → No → Excused → Yes. A day with no log yet (nil status) starts
    /// at Yes on first tap.
    /// Cycles off the day's actual raw log state (not the derived day-level
    /// `HabitCompletionStatus`, which collapses "genuinely marked missed"
    /// and "never touched" into the same `.no`) so the cycle always ends
    /// back at unselected/blank: complete → missed → excused → unselected
    /// → complete... An accidental tap is undone by tapping through to
    /// blank again, rather than being stuck forever cycling between the
    /// three resolved states.
    private func cycleDay(_ date: Date, logsByDay: [Date: HabitLog]) {
        let day = calendar.startOfDay(for: date)
        let current = logsByDay[day]?.occurrenceStatus(0) ?? .none
        setDay(date, to: current.next, logsByDay: logsByDay)
    }

    /// Applies a bulk day-level status, mutating the *exact* log object the
    /// calendar just displayed (via `logsByDay`, the same lookup `dayCell`
    /// used to compute what's on screen) rather than re-scanning `habitLogs`
    /// independently — those two lookups disagreeing (e.g. if a duplicate
    /// log ever existed for the same date) was why some days silently
    /// wouldn't budge: the tap was editing a log nothing was displaying.
    /// For a day with no log yet, the new log's arrays are fully set
    /// *before* it's inserted, so the model context never briefly observes
    /// an empty (all-untouched) log for a day that's actually being marked.
    /// The mutation runs with animations off so the color change can't be
    /// seen mid-interpolation.
    private func setDay(_ date: Date, to status: OccurrenceStatus, logsByDay: [Date: HabitLog]) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            let day = calendar.startOfDay(for: date)
            // Rerouted rather than call-swapped: this used `logsByDay` to
            // decide whether to create, which is a *different question*
            // than "does a log exist" — it asks what this screen last
            // rendered. That's how it could create a second log for a day
            // that already had one. It now goes through the same funnel as
            // every other write path; `logsByDay` remains only for
            // *display* (see `dayCell`).
            let log = habit.logOrCreate(on: day, context: modelContext, calendar: calendar, site: "HabitDetailView.setDay")
            log.setAll(to: status, timesPerDay: habit.timesPerDay)
        }
        refreshCoordinator.habitLogsChanged()
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    var subtitle: String? = nil
    var color: Color = .primary

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    NavigationStack {
        HabitDetailView(habit: Habit(name: "Drink Water", timesPerDay: 4))
    }
    .modelContainer(for: [TaskItem.self, ScheduledBlock.self, Shelf.self, CalendarSubscription.self, SchedulingRule.self, EligibleHoursWindow.self, Tag.self, NamedSchedule.self, Habit.self, HabitLog.self], inMemory: true)
}
