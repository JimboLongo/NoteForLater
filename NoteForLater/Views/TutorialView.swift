import SwiftUI

/// A swipeable, hands-on walkthrough of the app's core workflow — reached
/// from More > Tutorial. Each page pairs a short explanation with a small
/// live demo (its own local, throwaway state) so the interaction itself
/// teaches the concept rather than just describing it; nothing here reads
/// or writes real app data.
struct TutorialView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private let pageCount = 8

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    WelcomePage().tag(0)
                    CapturePage().tag(1)
                    ShelvesPage().tag(2)
                    SchedulingRulePage().tag(3)
                    CalendarPage().tag(4)
                    HabitsPage().tag(5)
                    SpecialShelvesPage().tag(6)
                    DailyCheckInsPage().tag(7)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                HStack {
                    if page > 0 {
                        Button("Back") {
                            withAnimation { page -= 1 }
                        }
                    }
                    Spacer()
                    if page < pageCount - 1 {
                        Button("Next") {
                            withAnimation { page += 1 }
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button("Done") { dismiss() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding()
            }
            .navigationTitle("Tutorial")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { dismiss() }
                }
            }
        }
    }
}

/// Shared chrome every page uses — an icon, a title, explanatory body
/// text, then whatever hands-on demo that page provides, all scrollable
/// so it still fits on a compact phone in landscape or with Dynamic Type
/// turned up.
private struct TutorialPage<Demo: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    let body_: String
    @ViewBuilder let demo: Demo

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: icon)
                    .font(.system(size: 44))
                    .foregroundStyle(iconColor)
                    .frame(width: 84, height: 84)
                    .background(iconColor.opacity(0.15), in: Circle())
                    .padding(.top, 24)

                Text(title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)

                Text(body_)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .fixedSize(horizontal: false, vertical: true)

                demo
                    .padding(.horizontal, 24)
                    .padding(.top, 4)

                Spacer(minLength: 40)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Page 1: Welcome

private struct WelcomePage: View {
    var body: some View {
        TutorialPage(
            icon: "sparkles",
            iconColor: .accentColor,
            title: "Welcome to NoteForLater",
            body_: "Capture anything the moment you think of it, then let the app sort out when it actually happens. This quick tour walks through the pieces — swipe to move through it, and try tapping the demos as you go."
        ) {
            EmptyView()
        }
    }
}

// MARK: - Page 2: Capture

private struct CapturePage: View {
    @State private var draft = ""
    @State private var demoItems: [String] = ["Call the dentist", "Return library books"]
    @FocusState private var isFocused: Bool

    var body: some View {
        TutorialPage(
            icon: "tray.and.arrow.down.fill",
            iconColor: .orange,
            title: "Capture First, Sort Later",
            body_: "The Inbox is a brain dump — type it and hit return, no decisions required yet. Try it below."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Type something to capture...", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .focused($isFocused)
                        .onSubmit(addDemoItem)
                    Button("Add", action: addDemoItem)
                        .buttonStyle(.borderedProminent)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(demoItems, id: \.self) { item in
                    HStack(spacing: 8) {
                        Image(systemName: "circle")
                            .foregroundStyle(.secondary)
                        Text(item)
                        Spacer()
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func addDemoItem() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        withAnimation {
            demoItems.insert(trimmed, at: 0)
        }
        draft = ""
    }
}

// MARK: - Page 3: Shelves

private struct ShelvesPage: View {
    private struct DemoShelf: Identifiable {
        let id = UUID()
        let name: String
        let icon: String
        let color: Color
    }

    private let demoShelves = [
        DemoShelf(name: "To-Do", icon: "checklist", color: .orange),
        DemoShelf(name: "Errands", icon: "cart", color: .green),
        DemoShelf(name: "Someday", icon: "lightbulb", color: .yellow)
    ]
    @State private var selected: UUID?

    var body: some View {
        TutorialPage(
            icon: "square.stack.3d.up.fill",
            iconColor: .green,
            title: "Shelves Hold Your Tasks",
            body_: "From the Inbox, route each item onto a shelf — your own buckets like To-Do, Errands, or Someday. Tap a shelf below to see it highlight."
        ) {
            HStack(spacing: 20) {
                ForEach(demoShelves) { shelf in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selected = shelf.id
                        }
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: shelf.icon)
                                .font(.title3)
                                .frame(width: 50, height: 50)
                                .background(shelf.color.opacity(selected == shelf.id ? 0.55 : 0.2))
                                .clipShape(Circle())
                                .overlay {
                                    if selected == shelf.id {
                                        Circle().stroke(shelf.color, lineWidth: 3)
                                    }
                                }
                                .scaleEffect(selected == shelf.id ? 1.1 : 1)
                            Text(shelf.name)
                                .font(.caption)
                                .foregroundStyle(selected == shelf.id ? shelf.color : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            if selected != nil {
                Text("That's it — the task now lives on this shelf, ready for the AI Scheduler to pick up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
        }
    }
}

// MARK: - Page 4: Scheduling Rules

private struct SchedulingRulePage: View {
    private enum DemoStrategy: String, CaseIterable, Identifiable {
        case fillToFit = "Fill to Fit"
        case maxDuration = "Max Duration"
        case maxTaskCount = "Max Task Count"
        var id: String { rawValue }

        var explanation: String {
            switch self {
            case .fillToFit: return "Packs in as many tasks as fit the window, back to back."
            case .maxDuration: return "Stops once a total time budget (say, 90 minutes) is used up."
            case .maxTaskCount: return "Stops once a set number of tasks (say, 3) are placed."
            }
        }
    }

    @State private var strategy: DemoStrategy = .fillToFit

    var body: some View {
        TutorialPage(
            icon: "clock.arrow.2.circlepath",
            iconColor: .blue,
            title: "Schedules Tell the AI Scheduler When",
            body_: "Attach a Schedule to a shelf — a day/time window plus a fill strategy — and the AI Scheduler pulls tasks from that shelf into that window automatically. Try each strategy below."
        ) {
            Picker("Strategy", selection: $strategy) {
                ForEach(DemoStrategy.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)

            Text(strategy.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
                .animation(.easeInOut(duration: 0.15), value: strategy)
        }
    }
}

// MARK: - Page 5: Calendar

private struct CalendarPage: View {
    @State private var isCompleted = false

    var body: some View {
        TutorialPage(
            icon: "calendar",
            iconColor: .accentColor,
            title: "Your Day, Laid Out",
            body_: "The Calendar tab shows everything the AI Scheduler placed. Tap a block's circle to mark it done, hold and drag to move it, or swipe left to remove it. Try the circle below."
        ) {
            HStack(spacing: 10) {
                Button {
                    withAnimation { isCompleted.toggle() }
                } label: {
                    ZStack {
                        Circle()
                            .fill(isCompleted ? Color.green : Color.clear)
                            .overlay(Circle().strokeBorder(isCompleted ? Color.green : Color.secondary.opacity(0.7), lineWidth: 1.5))
                        if isCompleted {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Draft the proposal")
                        .font(.subheadline.weight(.semibold))
                        .strikethrough(isCompleted)
                    Text("9:00 – 10:00 AM")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .opacity(isCompleted ? 0.5 : 1)
            .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

// MARK: - Page 6: Habits

private struct HabitsPage: View {
    private enum DemoStatus: CaseIterable {
        case none, complete, missed, excused

        var next: DemoStatus {
            switch self {
            case .none: return .complete
            case .complete: return .missed
            case .missed: return .excused
            case .excused: return .none
            }
        }

        var fill: Color {
            switch self {
            case .none: return Color.secondary.opacity(0.15)
            case .complete: return .green.opacity(0.6)
            case .missed: return .red.opacity(0.55)
            case .excused: return .gray.opacity(0.4)
            }
        }

        var icon: String? {
            switch self {
            case .none: return nil
            case .complete: return "checkmark"
            case .missed, .excused: return "xmark"
            }
        }

        var label: String {
            switch self {
            case .none: return "Not done yet"
            case .complete: return "Complete"
            case .missed: return "Missed"
            case .excused: return "Excused"
            }
        }
    }

    @State private var status: DemoStatus = .none

    var body: some View {
        TutorialPage(
            icon: "checkmark.seal.fill",
            iconColor: .purple,
            title: "Habits Track Themselves",
            body_: "Habits repeat on the days you pick, and can either land on the calendar at a fixed time or show up as a plain checklist item in the morning, midday, or evening. Tap the circle to cycle through a day's states."
        ) {
            VStack(spacing: 10) {
                Button {
                    withAnimation { status = status.next }
                } label: {
                    ZStack {
                        Circle().fill(status.fill)
                        if let icon = status.icon {
                            Image(systemName: icon)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                Text(status.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Page 7: 2-Minute + Recurring shelves

private struct SpecialShelvesPage: View {
    var body: some View {
        TutorialPage(
            icon: "2.circle.fill",
            iconColor: .brown,
            title: "Two Shelves With Special Powers",
            body_: "Turn these on from Settings > Special Shelves:\n\n• 2-Minute Tasks — a plain checklist above the calendar for the quick stuff you'll just knock out.\n\n• Recurring Tasks — set a task to repeat every few days/weeks/months, and it lands on the calendar at its own fixed time automatically, just like a habit."
        ) {
            EmptyView()
        }
    }
}

// MARK: - Page 8: Daily Check-Ins

private struct DailyCheckInsPage: View {
    var body: some View {
        TutorialPage(
            icon: "bell.badge.fill",
            iconColor: .yellow,
            title: "One Digest, Not a Dozen Pings",
            body_: "Instead of a separate notification for every habit and task, turn on Daily Check-Ins in Settings for up to three digest notifications a day — each one lists everything still open, and tapping it lets you check things off right there. Nightly Review, reachable from the More tab, walks you through today, your Inbox, and tomorrow's plan each evening."
        ) {
            EmptyView()
        }
    }
}

#Preview {
    TutorialView()
}
