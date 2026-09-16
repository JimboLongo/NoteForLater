import XCTest
import SwiftUI
import SwiftData
@testable import NoteForLater

/// Renders the actual `TaskReviewCard` through `UIHostingController` at the
/// exact point-width of an iPhone 17 (the user's own physical device — this
/// suite's simulator target, `4787BA85-1802-4B8C-8AA4-F88A4DA3752C`, is that
/// same model) and rasterizes it to a PNG, rather than reasoning about
/// string lengths — two shortened strings ("Scope" → "Pattern," then
/// "Weekday of month" → "Weekday") still wrapped on-device, so an estimate
/// isn't trustworthy evidence here. The PNG is written to a fixed path for
/// manual visual inspection.
final class RecurringTaskCardRenderTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: TaskItem.self, ScheduledBlock.self, Shelf.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    /// Worst-case Relative Date values: `.months` (the "On the" row only
    /// shows for this unit, post-redesign — the old mode toggle used to
    /// show it regardless of `recurrenceUnit`, but that field now
    /// actually gates it), `.weekdayOfMonth` (the "Weekday" row only
    /// shows for this scope, and it's `RelativeRecurrenceScope`'s own
    /// longest label, "Day of Week" vs. "Day of month"), `.fourth`
    /// (longest Position label, tied with "Second"/"Third" but distinct
    /// from the shelf-list's own worked example), Wednesday (longest
    /// weekday name in English), and `.specific` (`HabitOccurrenceTimeMode`'s
    /// own longest label, "Specific Time" vs. "AM"/"Midday"/"PM") — every
    /// `PickedMenuPicker` on this card gets its actual widest option
    /// selected at once, so the render shows every fixed-width column at
    /// once. "Every" is left un-picked so `isRepeatsConfigured` is false
    /// and the row auto-expands on `init`, without needing to simulate a
    /// tap.
    private func makeWorstCaseRelativeTask() -> TaskItem {
        let shelf = Shelf(name: "Recurring Tasks")
        shelf.isRecurringTasks = true
        context.insert(shelf)
        let task = TaskItem.makeForDirectCapture(title: "Water the garden", shelf: shelf)
        context.insert(task)
        task.isRecurring = true
        task.recurrenceUnit = .months
        task.recurrenceMode = .relativeDate
        task.relativeRecurrenceScope = .weekdayOfMonth
        task.relativeRecurrenceOrdinal = .fourth
        task.recurrenceTimeMode = .specific
        task.relativeRecurrenceWeekday = 4 // Wednesday
        return task
    }

    /// Non-recurring worst-case values: Due picked to a real date (proves
    /// the "decided-and-picked" state renders, not just "None"/"Not
    /// selected"), a two-part duration ("2h 15m" — the longer of
    /// `TaskItem.durationLabel`'s two non-trivial forms) with Divisible
    /// fully and validly answered so nothing auto-expands or reports
    /// missing, and High Priority — every row fully configured so all
    /// four collapse simultaneously and the screenshot shows every one of
    /// them in its resting, one-line state at once.
    private func makeWorstCaseNonRecurringTask() -> TaskItem {
        let task = TaskItem(title: "Renew the passport before the trip")
        context.insert(task)
        task.dueDateDecided = true
        task.dueDate = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 17))
        task.dueDatePicked = true
        task.durationPicked = true
        task.estimatedMinutes = 135
        task.divisiblePicked = true
        task.isDivisible = true
        task.minimumSegmentMinutes = TaskItem.validSegmentOptions(for: 135).first ?? 0
        task.priority = .high
        return task
    }

    private func renderAndSave(_ card: some View, to path: String) throws {
        let hosting = UIHostingController(rootView: card)
        let width = UIScreen.main.bounds.width
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 1400))
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        hosting.view.frame = window.bounds
        hosting.view.setNeedsLayout()
        hosting.view.layoutIfNeeded()
        // SwiftUI/UIHostingController settles its intrinsic content over a
        // couple of runloop turns — one `layoutIfNeeded()` right after
        // `makeKeyAndVisible()` can still catch it mid-layout.
        for _ in 0..<3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            hosting.view.layoutIfNeeded()
        }

        let renderer = UIGraphicsImageRenderer(bounds: hosting.view.bounds)
        let image = renderer.image { _ in
            hosting.view.drawHierarchy(in: hosting.view.bounds, afterScreenUpdates: true)
        }
        let data = try XCTUnwrap(image.pngData())
        try data.write(to: URL(fileURLWithPath: path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func test_patternRowFamily_rendersAtIPhone17Width_forVisualInspection() throws {
        let task = makeWorstCaseRelativeTask()
        let shelf = task.shelf!

        let card = TaskReviewCard(
            task: task,
            shelves: [shelf],
            onDiscard: {},
            onSkip: {},
            onMove: { _ in },
            onNext: {},
            onSnooze: { _ in }
        )
        .environment(\.modelContext, context)

        try renderAndSave(
            card,
            to: "/private/tmp/claude-501/-Users-jimmylong-Desktop-NoteForLater/e4869a73-1104-4360-97d1-303c92f0e0ca/scratchpad/pattern_row_render.png"
        )
    }

    func test_nonRecurringRows_renderAtIPhone17Width_forVisualInspection() throws {
        let task = makeWorstCaseNonRecurringTask()

        let card = TaskReviewCard(
            task: task,
            shelves: [],
            onDiscard: {},
            onSkip: {},
            onMove: { _ in },
            onNext: {},
            onSnooze: { _ in }
        )
        .environment(\.modelContext, context)

        try renderAndSave(
            card,
            to: "/private/tmp/claude-501/-Users-jimmylong-Desktop-NoteForLater/e4869a73-1104-4360-97d1-303c92f0e0ca/scratchpad/non_recurring_rows_render.png"
        )
    }
}
