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
/// isn't trustworthy evidence here.
///
/// **These tests compare against baselines checked into
/// `NoteForLaterTests/RenderBaselines/` and fail on any pixel difference.**
///
/// They did not always. Until now `renderAndSave` wrote a PNG to a scratch
/// directory and asserted `FileManager.fileExists` — it *emitted* images and
/// checked the write succeeded. Nothing compared them, so no visual
/// regression could ever turn this suite red, while the names read like
/// baselines and "539/539 passing" was repeatedly cited as covering
/// rendering across several stages of the card work. That is the spec's
/// *"tests whose failure mode is silence"* rule in its purest form, and it
/// is why the comparison lives here now rather than in whoever remembers to
/// run `cmp` by hand.
///
/// On failure, see `RenderBaselines/__Failures__/` — the diff overlay, the
/// actual render and the baseline are all written there, and the failure
/// message carries the changed-pixel count and bounding box.
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
    /// weekday name in English), and `.midday` (the widest label a *task*
    /// can now hold — "Specific Time" was wider but is habits-only, see
    /// `HabitOccurrenceTimeMode.taskSelectableCases`) — every
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
        // Was `.specific`, the longest `HabitOccurrenceTimeMode` label, for
        // the widest "Mode" column. A task can't be Specific Time any more,
        // so this picks the widest *selectable* one instead — the fixture's
        // job is still "every picker at its widest option at once".
        task.recurrenceTimeMode = .midday
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

    // MARK: - Rendering

    /// Pinned deliberately rather than read from the environment.
    ///
    /// `width` used to be `UIScreen.main.bounds.width`, which quietly made
    /// every baseline a function of *which simulator you happened to pick* —
    /// run the suite on an iPhone 16e and every fixture fails for a reason
    /// that has nothing to do with the code. 402pt is the iPhone 17 / 17 Pro
    /// point width (the user's own device); hard-coding it makes the render
    /// device-independent, so the baselines are valid on any simulator.
    ///
    /// `scale` is pinned to 2 rather than inherited from the device (3 on a
    /// Pro) purely for file size: these are checked into git, and every
    /// re-record adds another full copy to history forever. Scale 2 is 4x
    /// smaller than scale 3 and still resolves a one-character label change
    /// unambiguously.
    /// The moment every render fixture is evaluated against.
    ///
    /// Baselines must not depend on when the suite runs. `tail_recurring`
    /// went red with no code change because the card crossed an at-risk
    /// threshold partway through a day — the fixture has a due date and a
    /// toggled-on scheduling rule, so `isAtRisk` flipped as the day's slack
    /// ran out. Pinned here so that class of failure can't recur.
    ///
    /// Deliberately far from any fixture's own dates, so nothing lands on a
    /// boundary.
    static let renderAsOf = Calendar.current.date(
        from: DateComponents(year: 2026, month: 6, day: 1, hour: 9)
    )!

    private static let renderWidth: CGFloat = 402
    private static let renderHeight: CGFloat = 1400
    private static let renderScale: CGFloat = 2

    private func render(_ card: some View) -> UIImage {
        let hosting = UIHostingController(rootView: card)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: Self.renderWidth, height: Self.renderHeight))
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

        let format = UIGraphicsImageRendererFormat()
        format.scale = Self.renderScale
        format.opaque = true
        // Forces an 8-bit sRGB buffer. Left at its default the simulator
        // renders wide-gamut — 64 bits per pixel, 16 per channel — and the
        // baseline then can't survive its own round-trip: writing it to PNG
        // quantises to 8 bits, so comparing a fresh 16-bit render against the
        // reloaded 8-bit file differs by ±1 on roughly 10% of pixels purely
        // from rounding. Every fixture failed on identical content until this
        // line existed.
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(bounds: hosting.view.bounds, format: format)
        return renderer.image { _ in
            hosting.view.drawHierarchy(in: hosting.view.bounds, afterScreenUpdates: true)
        }
    }

    // MARK: - Baseline comparison

    /// Where the checked-in baselines live. Located from `#filePath` rather
    /// than the test bundle so no pbxproj resource registration is needed —
    /// this target registers its files explicitly, and a resource folder is
    /// one more thing to get wrong for no benefit.
    static var baselineDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("RenderBaselines")
    }

    /// Failure artifacts land next to the baselines — the first place anyone
    /// looks — and are gitignored. A red test that only says "the PNGs
    /// differ" is nearly useless; this directory is the actual output.
    static var failureDirectory: URL {
        baselineDirectory.appendingPathComponent("__Failures__")
    }

    /// Set `RECORD_RENDER_BASELINES=1` to overwrite every baseline with the
    /// current render. Deliberately not automatic: silently re-recording on
    /// mismatch is how a snapshot suite becomes a rubber stamp.
    ///
    /// From the command line the variable must be prefixed —
    /// `TEST_RUNNER_RECORD_RENDER_BASELINES=1` — because `xcodebuild` does
    /// not pass the calling shell's environment into the test process; it
    /// forwards only `TEST_RUNNER_`-prefixed variables, stripping the prefix
    /// on the way in. Setting it unprefixed looks like it works and silently
    /// does nothing. In a scheme's Test → Arguments → Environment Variables,
    /// use the unprefixed name.
    private var isRecording: Bool {
        ProcessInfo.processInfo.environment["RECORD_RENDER_BASELINES"] == "1"
    }

    /// Renders `card` and asserts it matches the checked-in baseline
    /// **exactly**, pixel for pixel.
    ///
    /// **Why exact and not a tolerance.** Tolerance sounds like the robust
    /// choice and isn't, because it doesn't address what actually breaks
    /// these: an Xcode or simulator-iOS bump changes glyph rasterization
    /// across *every* character on the card. That's a large-area change, not
    /// a small-delta one, so a tolerance loose enough to absorb it would also
    /// be loose enough to hide a renamed label — the exact thing the suite
    /// exists to catch. Exact comparison keeps the signal clean and makes the
    /// noise legible instead: *all* fixtures red at once means the
    /// environment moved (re-record), *one* fixture red means the code did.
    /// The manifest check below says which, in the failure message, so nobody
    /// has to work that out from scratch.
    ///
    /// Comparison is on decoded sRGB pixels, not on the PNG file bytes — a
    /// different libpng or encoder setting would change the file without
    /// changing a single pixel, and that must not fail.
    private func assertMatchesBaseline(
        _ card: some View,
        named name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let image = render(card)
        let baselineURL = Self.baselineDirectory.appendingPathComponent("\(name).png")

        if isRecording {
            try FileManager.default.createDirectory(at: Self.baselineDirectory, withIntermediateDirectories: true)
            try XCTUnwrap(image.pngData()).write(to: baselineURL)
            try Self.writeManifest()
            return
        }

        guard FileManager.default.fileExists(atPath: baselineURL.path) else {
            try writeFailureArtifact(image, named: "\(name).actual")
            XCTFail(
                """
                No baseline for "\(name)".
                Current render written to \(Self.failureDirectory.path)/\(name).actual.png — \
                check it looks right, then record it:
                  TEST_RUNNER_RECORD_RENDER_BASELINES=1 xcodebuild test -project NoteForLater.xcodeproj \
                -scheme NoteForLater -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
                -only-testing:NoteForLaterTests/RecurringTaskCardRenderTests
                """,
                file: file, line: line
            )
            return
        }

        let actual = try Self.pixels(of: image)
        let expectedImage = try XCTUnwrap(UIImage(contentsOfFile: baselineURL.path))
        let expected = try Self.pixels(of: expectedImage)

        guard actual.width == expected.width, actual.height == expected.height else {
            try writeFailureArtifact(image, named: "\(name).actual")
            XCTFail(
                """
                "\(name)" changed size: baseline \(expected.width)x\(expected.height), \
                now \(actual.width)x\(actual.height).\(Self.environmentNote())
                Actual render: \(Self.failureDirectory.path)/\(name).actual.png
                """,
                file: file, line: line
            )
            return
        }

        guard actual.bytes != expected.bytes else { return }

        let report = Self.diff(actual: actual, expected: expected)
        try writeFailureArtifact(image, named: "\(name).actual")
        try writeFailureArtifact(expectedImage, named: "\(name).expected")
        try writeFailureData(report.overlayPNG, named: "\(name).diff")

        XCTFail(
            """
            "\(name)" does not match its baseline.
            \(report.changedPixels) of \(actual.width * actual.height) pixels differ \
            (\(String(format: "%.3f", report.changedFraction * 100))%).
            Changed region: x \(report.bbox.minX)–\(report.bbox.maxX), \
            y \(report.bbox.minY)–\(report.bbox.maxY) \
            (\(report.bbox.maxX - report.bbox.minX + 1)x\(report.bbox.maxY - report.bbox.minY + 1)px).
            \(Self.environmentNote())
            Written to \(Self.failureDirectory.path)/:
              \(name).diff.png      — changed pixels in red over a dimmed render
              \(name).actual.png    — what the code renders now
              \(name).expected.png  — the checked-in baseline
            If this change is intended, re-record:
              TEST_RUNNER_RECORD_RENDER_BASELINES=1 xcodebuild test -project NoteForLater.xcodeproj \
            -scheme NoteForLater -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
            -only-testing:NoteForLaterTests/RecurringTaskCardRenderTests
            """,
            file: file, line: line
        )
    }

    // MARK: - Pixel plumbing

    private struct Bitmap {
        let width: Int
        let height: Int
        let bytes: [UInt8]   // RGBA, 4 bytes per pixel
    }

    /// Decodes into a fixed sRGB RGBA buffer. Going through an explicit
    /// context rather than reading `cgImage` bytes directly normalizes
    /// colorspace, bitmap layout and row padding, so two images that look
    /// identical can't compare unequal over how they happen to be stored.
    /// NOTE on `withUnsafeMutableBytes`: the buffer must be held open across
    /// the `draw`. Writing this the obvious way —
    /// `CGContext(data: &bytes, ...)` and then drawing on the next line —
    /// compiles, runs, and is undefined behaviour: `&bytes` yields a pointer
    /// valid only for the duration of that one call, so the draw lands in
    /// memory the array no longer owns. It happened not to misbehave here,
    /// which is the worst way for UB to present — fixed on sight rather than
    /// left to bite later.
    private static func pixels(of image: UIImage) throws -> Bitmap {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drew = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(drew, "Could not create an sRGB bitmap context for comparison")
        return Bitmap(width: width, height: height, bytes: bytes)
    }

    private struct DiffReport {
        let changedPixels: Int
        let changedFraction: Double
        let bbox: (minX: Int, minY: Int, maxX: Int, maxY: Int)
        let overlayPNG: Data
    }

    /// Builds the bounding box of changed pixels and an overlay image — the
    /// render dimmed to grey with every differing pixel painted red. The
    /// bbox is the part worth reading: "the files differ" is noise, whereas
    /// "everything that moved is inside these two rows" is a statement that
    /// the rest of the card is untouched.
    private static func diff(actual: Bitmap, expected: Bitmap) -> DiffReport {
        var changed = 0
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        var overlay = [UInt8](repeating: 0, count: actual.bytes.count)

        for y in 0..<actual.height {
            for x in 0..<actual.width {
                let i = (y * actual.width + x) * 4
                let same = actual.bytes[i] == expected.bytes[i]
                    && actual.bytes[i + 1] == expected.bytes[i + 1]
                    && actual.bytes[i + 2] == expected.bytes[i + 2]
                    && actual.bytes[i + 3] == expected.bytes[i + 3]
                if same {
                    // Dim to grey so the red reads at a glance.
                    let luma = UInt8((Int(actual.bytes[i]) + Int(actual.bytes[i + 1]) + Int(actual.bytes[i + 2])) / 3)
                    let dimmed = 160 + luma / 4
                    overlay[i] = dimmed; overlay[i + 1] = dimmed; overlay[i + 2] = dimmed; overlay[i + 3] = 255
                } else {
                    changed += 1
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                    overlay[i] = 255; overlay[i + 1] = 0; overlay[i + 2] = 0; overlay[i + 3] = 255
                }
            }
        }

        let png = overlayPNG(bytes: overlay, width: actual.width, height: actual.height)
        return DiffReport(
            changedPixels: changed,
            changedFraction: Double(changed) / Double(actual.width * actual.height),
            bbox: (minX, minY, maxX, maxY),
            overlayPNG: png
        )
    }

    private static func overlayPNG(bytes: [UInt8], width: Int, height: Int) -> Data {
        var mutable = bytes
        // Same lifetime rule as `pixels(of:)` above — `makeImage()` copies,
        // so it's safe, but only from inside the closure.
        let cgImage: CGImage? = mutable.withUnsafeMutableBytes { raw in
            CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.makeImage()
        }
        guard let cgImage else { return Data() }
        return UIImage(cgImage: cgImage).pngData() ?? Data()
    }

    // MARK: - Environment manifest

    /// What the baselines were recorded under. Its whole job is to turn the
    /// brittleness of exact comparison from *confusing* into *routine*: when
    /// the simulator's iOS version has moved, the failure says so instead of
    /// leaving someone to diff PNGs wondering what they broke.
    private static var manifestURL: URL { baselineDirectory.appendingPathComponent("manifest.json") }

    private static var currentEnvironment: [String: String] {
        [
            "iosVersion": UIDevice.current.systemVersion,
            "width": "\(Int(renderWidth))",
            "height": "\(Int(renderHeight))",
            "scale": "\(Int(renderScale))",
        ]
    }

    private static func writeManifest() throws {
        let data = try JSONSerialization.data(
            withJSONObject: currentEnvironment, options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: manifestURL)
    }

    private static func environmentNote() -> String {
        guard let data = try? Data(contentsOf: manifestURL),
              let recorded = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return "" }
        let current = currentEnvironment
        let drift = current.filter { recorded[$0.key] != $0.value }
        guard !drift.isEmpty else { return "" }
        let detail = drift
            .sorted { $0.key < $1.key }
            .map { "\($0.key): baseline \(recorded[$0.key] ?? "?") vs now \($0.value)" }
            .joined(separator: ", ")
        return """

            NOTE: the render environment has changed since these baselines were \
            recorded (\(detail)). If every fixture is failing, that's the cause — \
            re-record rather than hunting for a code regression.
            """
    }

    private func writeFailureArtifact(_ image: UIImage, named name: String) throws {
        try writeFailureData(image.pngData() ?? Data(), named: name)
    }

    private func writeFailureData(_ data: Data, named name: String) throws {
        try FileManager.default.createDirectory(at: Self.failureDirectory, withIntermediateDirectories: true)
        try data.write(to: Self.failureDirectory.appendingPathComponent("\(name).png"))
    }

    func test_patternRowFamily_matchesBaseline() throws {
        let task = makeWorstCaseRelativeTask()
        let shelf = task.shelf!

        let card = TaskReviewCard(
            task: task,
            shelves: [shelf],
            onDiscard: {},
            onSkip: {},
            onMove: { _ in },
            onNext: {},
            onSnooze: { _ in },
            asOf: Self.renderAsOf
        )
        .environment(\.modelContext, context)

        try assertMatchesBaseline(card, named: "pattern_row_render")
    }

    func test_nonRecurringRows_matchBaseline() throws {
        let task = makeWorstCaseNonRecurringTask()

        let card = TaskReviewCard(
            task: task,
            shelves: [],
            onDiscard: {},
            onSkip: {},
            onMove: { _ in },
            onNext: {},
            onSnooze: { _ in },
            asOf: Self.renderAsOf
        )
        .environment(\.modelContext, context)

        try assertMatchesBaseline(card, named: "non_recurring_rows_render")
    }

    /// A task whose shelf turns on *every* tracking flag and carries a
    /// scheduling rule, so the tail rows — Tags, Shelf, Eligible
    /// Schedules, Remind In — all render. The existing worst-case
    /// fixtures leave Eligible Schedules and Remind In hidden, so without
    /// this the tail is unprotected by any render baseline.
    private func makeFullTailTask(recurring: Bool) -> TaskItem {
        let shelf = Shelf(name: "Errands")
        shelf.tracksFutureReminder = true
        context.insert(shelf)
        let rule = SchedulingRule(shelf: shelf, fillStrategy: .fillToFit)
        context.insert(rule)
        shelf.schedulingRules = [rule]

        let task = TaskItem(title: "Renew the passport", shelf: shelf, estimatedMinutes: 120)
        context.insert(task)
        task.tags = ["errand", "admin"]
        task.includedSchedulingRuleIDs = [rule.id]
        task.nextStepDecided = true
        task.nextStepAnsweredYes = true
        task.nextStep = "Find the old one"
        TaskItem.selectDuration(120, on: task)
        TaskItem.selectDivisibleSegment(30, on: task)
        task.priority = .high
        task.dueDateDecided = true
        task.dueDate = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 17))
        task.dueDatePicked = true
        if recurring {
            task.isRecurring = true
            task.recurrenceTimeMode = .midday
            task.recurrenceTimeModePicked = true
            task.recurrenceIntervalPicked = true
            // A *fixed* date, not `.now`. This read the clock, so the
            // rendered "Can Start By" value changed every midnight and the
            // baseline went red on a day nobody had touched the code —
            // "Wed, Sep 16" became "Thu, Sep 17".
            //
            // Pinning `asOf` fixed the *evaluation* moment (at-risk); it
            // does nothing for a fixture whose *data* comes from the clock.
            // Two separate axes, and only one of them was closed.
            task.setStartDate(Self.renderAsOf)
        }
        return task
    }

    private func renderCard(_ task: TaskItem, to name: String) throws {
        let card = TaskReviewCard(
            task: task,
            shelves: task.shelf.map { [$0] } ?? [],
            onDiscard: {}, onSkip: {}, onMove: { _ in }, onNext: {}, onSnooze: { _ in },
            asOf: Self.renderAsOf
        )
        .environment(\.modelContext, context)
        try assertMatchesBaseline(card, named: name)
    }

    /// Baselines for the row-list consolidation: the whole point of that
    /// change is that presentation is untouched, so these renders should
    /// come out pixel-identical before and after. Rendering was confirmed
    /// deterministic across repeat runs before relying on that.
    func test_fullTailRows_recurring_render() throws {
        try renderCard(makeFullTailTask(recurring: true), to: "tail_recurring")
    }

    func test_fullTailRows_nonRecurring_render() throws {
        try renderCard(makeFullTailTask(recurring: false), to: "tail_nonrecurring")
    }

    /// The 2-Minute shelf, configured the way its fields are now decided:
    /// by its own toggles rather than by hardcoded `isTwoMinute` checks.
    ///
    /// **This fixture exists because that change had no render coverage at
    /// all** — no baseline used a 2-Minute shelf, so removing the hardcoding
    /// could have altered that card arbitrarily and every fixture would
    /// still have matched. Exactly the gap that let earlier changes through.
    func test_twoMinuteShelf_render() throws {
        let task = makeFullTailTask(recurring: false)
        let shelf = task.shelf!
        shelf.isTwoMinuteTasks = true
        shelf.hasDueDates = false
        shelf.hasPriority = false
        shelf.tracksTags = false
        TaskItem.selectDuration(2, on: task)
        try renderCard(task, to: "two_minute_shelf")
    }

    /// Duration must never be `.hidden` on the shelf its own value selects —
    /// see `Shelf.durationIsTheDestinationTrigger`.
    ///
    /// Pinned here rather than expressed as a branch in `CardRow`, because
    /// today's non-tracking fallback is already `.greyed` and a branch
    /// returning the same value on both sides would document nothing. If
    /// that fallback is ever changed to `.hidden`, this fails and the
    /// trigger shelf has to be excepted explicitly.
    func test_duration_isNeverHiddenOnTheDestinationTriggerShelf() throws {
        let task = makeFullTailTask(recurring: false)
        let shelf = task.shelf!
        shelf.isTwoMinuteTasks = true
        TaskItem.selectDuration(2, on: task)

        for tracksDuration in [true, false] {
            shelf.tracksDuration = tracksDuration
            XCTAssertNotEqual(
                CardRow.duration.visibility(task: task, shelf: shelf), .hidden,
                "Duration is the control that selects this shelf — hiding it strands the task (tracksDuration: \(tracksDuration))"
            )
        }
    }

    /// A shelf that tracks nothing, so the greyed/hidden states render.
    func test_nonTrackingShelf_render() throws {
        let task = makeFullTailTask(recurring: false)
        let shelf = task.shelf!
        shelf.tracksDuration = false
        shelf.hasDueDates = false
        shelf.hasPriority = false
        shelf.hasNextStep = false
        try renderCard(task, to: "tail_nontracking")
    }

    /// Keeps every fixture clear of the at-risk boundary at `renderAsOf`.
    ///
    /// **This is the guard; the `asOf` injection is the fix.** Once the card
    /// evaluates against a pinned moment, a baseline can no longer drift
    /// with wall-clock time — that is structural, and nothing can test it by
    /// varying `asOf`, because at-risk is *supposed* to differ at different
    /// moments. (I wrote that test first: it rendered the same fixture in
    /// January and December and asserted they matched. They don't, and
    /// shouldn't — a September due date really is past due by December.)
    ///
    /// What can still go wrong is a fixture sitting so close to the at-risk
    /// boundary that an unrelated edit — a date nudged, a duration changed,
    /// a rule toggled — silently flips it and shows up as an inscrutable
    /// 50%-of-pixels diff. That is exactly how `tail_recurring` failed. This
    /// names the condition directly, so the next time it happens the failure
    /// says which fixture and why instead of handing over a picture.
    func test_fixturesAreNotAtRiskAtTheRenderMoment() throws {
        let fixtures: [(name: String, task: TaskItem)] = [
            ("tail_recurring", makeFullTailTask(recurring: true)),
            ("tail_nonrecurring", makeFullTailTask(recurring: false)),
            ("pattern_row_render", makeWorstCaseRelativeTask()),
            ("non_recurring_rows_render", makeWorstCaseNonRecurringTask()),
        ]
        for (name, task) in fixtures {
            XCTAssertNil(
                task.atRiskBlocker(asOf: Self.renderAsOf),
                """
                Fixture "\(name)" is at risk at renderAsOf, so its baseline \
                carries an at-risk banner that a small unrelated change could \
                flip. Move the fixture's dates away from the boundary rather \
                than re-recording.
                """
            )
        }
    }

    /// No fixture may build a rendered date from the clock.
    ///
    /// Companion to `test_fixturesAreNotAtRiskAtTheRenderMoment`, which
    /// guards the *evaluation* axis. This guards the *data* axis, which that
    /// one cannot see: `makeFullTailTask` called
    /// `setStartDate(startOfDay(for: .now))`, so the rendered "Can Start By"
    /// value changed at every midnight and a baseline went red on a day
    /// nobody had touched the code. Pinning `asOf` did not help, because the
    /// date was baked into the fixture before evaluation ever happened.
    ///
    /// Asserted *positively* — the start date must be the pinned constant —
    /// rather than as "must not be today". The first version did the latter
    /// and was wrong twice over: a hardcoded literal that happens to equal
    /// today is not drift, and these fixtures' due dates are literals
    /// evaluated against `renderAsOf`, not against the real clock. A
    /// positive check fails the moment `.now` comes back and never fires on
    /// a date that is merely unlucky.
    func test_fixtureStartDatesArePinned_notDerivedFromTheClock() {
        let expected = Calendar.current.startOfDay(for: Self.renderAsOf)
        for (name, task) in [
            ("tail_recurring", makeFullTailTask(recurring: true)),
            ("tail_nonrecurring", makeFullTailTask(recurring: false)),
        ] {
            guard let start = task.startDate else { continue }
            XCTAssertEqual(
                Calendar.current.startOfDay(for: start), expected,
                "\(name)'s start date must be the pinned renderAsOf day, or the baseline drifts at midnight"
            )
        }
    }

    /// Guards the repo against the cost of these baselines.
    ///
    /// `UIImage.pngData()` writes PNGs about 4x larger than the content
    /// needs — the five fixtures came to 12.2 MB as recorded, and *every*
    /// re-record adds another full copy to git history permanently.
    /// `scripts/optimize-render-baselines.py` re-encodes them losslessly to
    /// 2.9 MB.
    ///
    /// That script is easy to forget, and a forgotten optimisation step is
    /// invisible — which is the same shape of problem as the missing
    /// comparison this whole file just fixed. So it's asserted rather than
    /// documented: re-record, skip the script, and the suite says so.
    func test_baselinesAreLosslesslyCompressed() throws {
        let budget = 1_200_000
        let files = try FileManager.default.contentsOfDirectory(
            at: Self.baselineDirectory, includingPropertiesForKeys: [.fileSizeKey]
        ).filter { $0.pathExtension == "png" }

        XCTAssertFalse(files.isEmpty, "No baselines found at \(Self.baselineDirectory.path)")

        let oversized = try files
            .map { (name: $0.lastPathComponent, size: try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
            .filter { $0.size > budget }
            .sorted { $0.size > $1.size }

        XCTAssertTrue(
            oversized.isEmpty,
            """
            \(oversized.count) baseline(s) are larger than \(budget / 1024) KB, which means \
            they were recorded but not re-encoded:
            \(oversized.map { "  \($0.name) — \($0.size / 1024) KB" }.joined(separator: "\n"))
            Run: python3 scripts/optimize-render-baselines.py
            It is pixel-lossless (it verifies that itself), so the comparison \
            tests above keep passing.
            """
        )
    }
}

