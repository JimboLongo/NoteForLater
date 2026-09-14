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

    /// Worst-case Relative Date values: `.weekdayOfMonth` (the "Weekday"
    /// row only shows for this scope), `.fourth` (longest Position label,
    /// tied with "Second"/"Third" but distinct from the shelf-list's own
    /// worked example), and Wednesday (longest weekday name in English).
    /// "Every" is left un-picked so `isRepeatsConfigured` is false and the
    /// row auto-expands on `init`, without needing to simulate a tap.
    private func makeWorstCaseRelativeTask() -> TaskItem {
        let shelf = Shelf(name: "Recurring Tasks")
        shelf.isRecurringTasks = true
        context.insert(shelf)
        let task = TaskItem.makeForDirectCapture(title: "Water the garden", shelf: shelf)
        context.insert(task)
        task.isRecurring = true
        task.recurrenceMode = .relativeDate
        task.relativeRecurrenceScope = .weekdayOfMonth
        task.relativeRecurrenceOrdinal = .fourth
        task.relativeRecurrenceWeekday = 4 // Wednesday
        return task
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
        let path = "/private/tmp/claude-501/-Users-jimmylong-Desktop-NoteForLater/e4869a73-1104-4360-97d1-303c92f0e0ca/scratchpad/pattern_row_render.png"
        try data.write(to: URL(fileURLWithPath: path))

        // The render itself is the evidence (inspected visually afterward);
        // this assertion just confirms the file landed so a stale image
        // from a previous run is never mistaken for this one.
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }
}
