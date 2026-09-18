import XCTest
import SwiftUI
import SwiftData
@testable import NoteForLater

/// **Pins that a calendar block's three completion states are actually
/// distinguishable on screen — in rendered pixels, not in the arguments
/// passed to the renderer.**
///
/// This exists because of a specific bug, and the shape of that bug is the
/// reason the assertion is written this way.
///
/// `ScheduledBlock.isCompleted` is `{ status == .complete }`, so `.missed`
/// and `.none` both read `false`. `DayTimelineSegment.completeCircle(for:)`
/// passed `isCompleted: block.isCompleted` for any non-recurring block and
/// left `isMissed` at its `false` default — so cycling a task block to
/// `.missed` wrote the right status and drew an empty outline, **pixel-
/// identical to untouched**. The row fade had the same gap (`isRecurringMissed`
/// was gated on `task.isRecurring`). Two taps looked like one toggle.
///
/// **Why distinguishability rather than a baseline.** A checked-in PNG pins
/// *appearance*; this pins the *property that broke* — that no two states
/// collide. A baseline of the broken code would have been perfectly green,
/// because the broken render was self-consistent. It only looks wrong next
/// to the other two states.
///
/// This is the third instance this session of "the mechanism exists but is
/// not connected to what you see" (see docs/session-handoff.md), and the
/// only one of the three that a test can catch at all.
final class BlockStatusCircleRenderTests: XCTestCase {

    /// Window/canvas size. Comfortably larger than the 15pt circle so UIKit
    /// actually lays the window out (see the comment in `pixels`).
    private static let canvas: CGFloat = 100

    /// Rendered at 4x so the 15pt circle has enough pixels for the
    /// checkmark/X glyphs to register as real differences rather than a
    /// handful of antialiased edge samples.
    private func pixels(_ status: OccurrenceStatus) throws -> [UInt8] {
        // **Hosted in a 100pt window, not a 15pt one.** A window sized to
        // the circle itself rendered fully white — UIKit will not lay out
        // and draw a window that small, and the failure is silent: every
        // state comes back identical, so the test fails for a reason that
        // has nothing to do with the code under test. Caught by dumping the
        // buffer (all 22500 pixels white) rather than by reasoning about it.
        let view = BlockStatusCircle(status: status)
            .frame(width: Self.canvas, height: Self.canvas)
            // An explicit ground: the circle's own `.none` state is
            // `Color.clear`, and comparing transparent pixels against a
            // host-provided background is how a "difference" can appear or
            // vanish for reasons unrelated to the circle.
            .background(Color.white)

        // **A real key window, and run-loop turns to let SwiftUI settle.**
        // Without both, `drawHierarchy(afterScreenUpdates: true)` captures a
        // blank buffer and every state compares equal — which is a *passing*
        // render harness producing a *failing* test for the wrong reason.
        // Copied deliberately from `RecurringTaskCardRenderTests.render`
        // rather than reinvented; my first attempt hosted the view with no
        // window and all three states came back identical, complete
        // included.
        let hosting = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: Self.canvas, height: Self.canvas))
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        hosting.view.frame = window.bounds
        hosting.view.setNeedsLayout()
        hosting.view.layoutIfNeeded()
        for _ in 0..<3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            hosting.view.layoutIfNeeded()
        }

        let format = UIGraphicsImageRendererFormat()
        // Wide-gamut 64bpp cannot survive a round-trip to 8-bit sRGB — same
        // reason the card baselines pin this.
        format.preferredRange = .standard
        format.opaque = true
        format.scale = 4

        let renderer = UIGraphicsImageRenderer(bounds: hosting.view.bounds, format: format)
        let image = renderer.image { _ in
            hosting.view.drawHierarchy(in: hosting.view.bounds, afterScreenUpdates: true)
        }

        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { raw in
            let context = try XCTUnwrap(CGContext(
                data: raw.baseAddress,
                width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }

    private func differingPixelCount(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
        XCTAssertEqual(lhs.count, rhs.count, "renders must be the same size to compare")
        var differing = 0
        for i in stride(from: 0, to: min(lhs.count, rhs.count), by: 4) where
            lhs[i] != rhs[i] || lhs[i + 1] != rhs[i + 1] || lhs[i + 2] != rhs[i + 2] || lhs[i + 3] != rhs[i + 3] {
            differing += 1
        }
        return differing
    }

    /// **The regression guard.** Reverting `completeCircle(for:)` to pass
    /// `isCompleted: block.isCompleted` with `isMissed` defaulted fails this
    /// with 0 differing pixels.
    func test_missedRendersDifferentlyFromUntouched() throws {
        let untouched = try pixels(.none)
        let missed = try pixels(.missed)

        let differing = differingPixelCount(untouched, missed)
        XCTAssertGreaterThan(
            differing, 0,
            """
            A missed block renders identically to an untouched one, so the \
            second tap of the three-state cycle is invisible and the row \
            reads as a two-state toggle. This is what shipped.
            """
        )
    }

    /// The other two pairings, so a future change can't collapse a different
    /// pair while keeping this one honest.
    func test_allThreeStatesAreMutuallyDistinguishable() throws {
        let states: [OccurrenceStatus] = [.none, .complete, .missed]
        let rendered = try states.map { (name: $0.rawValue, bytes: try pixels($0)) }

        for i in rendered.indices {
            for j in rendered.indices where j > i {
                XCTAssertGreaterThan(
                    differingPixelCount(rendered[i].bytes, rendered[j].bytes), 0,
                    "\"\(rendered[i].name)\" and \"\(rendered[j].name)\" render identically"
                )
            }
        }
    }

}

/// **The half the render test above cannot reach.**
///
/// `BlockStatusCircleRenderTests` proves the circle *can* draw three states.
/// It passed against the broken code, because the bug was never in the
/// circle — the call site computed `isCompleted: block.isCompleted` and let
/// `isMissed` default to `false`, so the circle was simply never asked for
/// the third state. A component test with hand-written arguments cannot see
/// that, and mine didn't: sabotaging the fix left all three green.
///
/// So this tests the *derivation* instead — the question the call site
/// actually asks — and the signature change (`BlockStatusCircle` takes an
/// `OccurrenceStatus`, not two `Bool`s, one of them defaultable) is what
/// covers the wiring between them, by making the omission unrepresentable
/// rather than merely wrong.
final class BlockDisplayStatusTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: TaskItem.self, ScheduledBlock.self, Shelf.self, Tag.self,
                TaskCompletionRecord.self, RecurringTaskLog.self, Habit.self, HabitLog.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func makeBlock(recurring: Bool) -> ScheduledBlock {
        let shelf = Shelf(name: "Work")
        context.insert(shelf)
        let task = TaskItem(title: "Write the thing", shelf: shelf)
        task.isRecurring = recurring
        context.insert(task)
        let date = day(2026, 1, 5)
        let block = ScheduledBlock(date: date, startTime: date, endTime: date.addingTimeInterval(1800), task: task)
        context.insert(block)
        return block
    }

    /// **The regression guard.** This is the state that rendered as
    /// untouched: an ordinary task block cycled to `.missed`.
    func test_ordinaryBlock_reportsMissed_notNone() throws {
        let block = makeBlock(recurring: false)
        block.status = .missed

        XCTAssertEqual(
            ScheduleReviewViewModel.blockDisplayStatus(block, context: context), .missed,
            """
            A missed ordinary block must report .missed. Reading block.isCompleted \
            instead collapses it to .none — which is what drew it identical to \
            untouched on the day calendar and Review Planned Schedule.
            """
        )
        XCTAssertFalse(block.isCompleted, "and isCompleted still reads false, which is exactly why it can't be the source")
    }

    func test_ordinaryBlock_reportsCompleteAndNone() throws {
        let block = makeBlock(recurring: false)
        XCTAssertEqual(ScheduleReviewViewModel.blockDisplayStatus(block, context: context), OccurrenceStatus.none)

        block.status = .complete
        XCTAssertEqual(ScheduleReviewViewModel.blockDisplayStatus(block, context: context), .complete)
    }

    /// A recurring task's block is a mirror — the log wins, even when the
    /// mirror disagrees.
    func test_recurringBlock_readsThroughToTheLog_notTheMirror() throws {
        let block = makeBlock(recurring: true)
        let task = try XCTUnwrap(block.task)
        block.status = .complete   // a stale mirror

        _ = task.cycleRecurringOccurrence(on: block.date, context: context)   // -> .complete
        _ = task.cycleRecurringOccurrence(on: block.date, context: context)   // -> .missed

        XCTAssertEqual(
            ScheduleReviewViewModel.blockDisplayStatus(block, context: context), .missed,
            "RecurringTaskLog is the source of truth; block.status is only a mirror"
        )
    }

    /// A habit block has no task at all — it must fall through to its own
    /// status rather than trapping on the `block.task` unwrap.
    func test_blockWithNoTask_usesItsOwnStatus() throws {
        let date = day(2026, 1, 5)
        let block = ScheduledBlock(date: date, startTime: date, endTime: date.addingTimeInterval(900), task: nil)
        context.insert(block)
        block.status = .missed

        XCTAssertEqual(ScheduleReviewViewModel.blockDisplayStatus(block, context: context), OccurrenceStatus.missed)
    }
}
