import XCTest
@testable import NoteForLater

/// Characterization tests for `DayTimelineGeometry` — the day calendar's
/// scroll-space arithmetic.
///
/// **Written before the `DayTimelineGridView` structural split, on
/// purpose.** These sums are what translate a grid-local touch into the
/// shared ScrollView's content space, so they decide where a dragged
/// block actually lands. Before this file existed, nothing in the suite
/// referenced `precedingContentHeight`, `amSectionHeight`, or the
/// `scrollToRoughlyNow` offset — meaning the riskiest part of that split
/// had nothing to fail against. This pins the current behavior first, so
/// the extraction has a regression net rather than being verified only by
/// "it still compiles."
///
/// These are deliberately *characterization* tests: they assert what the
/// arithmetic does today, derived by hand from the values, not what it
/// arguably should do. If one fails after a refactor, the refactor moved
/// the geometry — that's the signal.
///
/// Scope limit worth stating plainly: this covers the arithmetic only. It
/// cannot cover *when* SwiftUI reports a section's height, so a layout
/// pass that reports a stale or differently-timed height would still slip
/// past a green run here. That half needs an on-device drag check.
final class DayTimelineGeometryTests: XCTestCase {

    // MARK: - precedingContentHeight (morning / single segment)

    func test_precedingContentHeight_sumsTwoMinuteAndMorningSections() {
        XCTAssertEqual(
            DayTimelineGeometry.precedingContentHeight(twoMinuteSectionHeight: 80, amSectionHeight: 120),
            200
        )
    }

    /// The ordinary empty-day case — no 2-Minute tasks, no morning
    /// habits — must contribute nothing rather than any baseline inset.
    func test_precedingContentHeight_bothSectionsAbsent_isZero() {
        XCTAssertEqual(
            DayTimelineGeometry.precedingContentHeight(twoMinuteSectionHeight: 0, amSectionHeight: 0),
            0
        )
    }

    // MARK: - afternoonPrecedingContentHeight (split day)

    /// Fail-then-pass target. The afternoon segment sits below *four*
    /// stacked things, and the morning grid's own rendered height is the
    /// term most easily dropped — without it every afternoon drop lands
    /// short by exactly the height of the morning grid.
    func test_afternoonPrecedingContentHeight_includesMorningGridHeightAndMiddaySection() {
        XCTAssertEqual(
            DayTimelineGeometry.afternoonPrecedingContentHeight(
                twoMinuteSectionHeight: 80,
                amSectionHeight: 120,
                morningDayHeight: 1200,
                middaySectionHeight: 90
            ),
            1490
        )
    }

    /// The afternoon sum must strictly exceed the morning sum by the
    /// grid-plus-midday content between them — the relationship that
    /// makes the two segments address different parts of one scroll
    /// space rather than overlapping.
    func test_afternoonPrecedingContentHeight_exceedsMorningByGridPlusMidday() {
        let morning = DayTimelineGeometry.precedingContentHeight(
            twoMinuteSectionHeight: 40, amSectionHeight: 60
        )
        let afternoon = DayTimelineGeometry.afternoonPrecedingContentHeight(
            twoMinuteSectionHeight: 40, amSectionHeight: 60,
            morningDayHeight: 900, middaySectionHeight: 75
        )

        XCTAssertEqual(afternoon - morning, 975)
    }

    // MARK: - scrollToRoughlyNowOffset

    /// Not split: a plain header offset plus the quarter-distance from
    /// the visible range's start. 4 quarters past the start at the
    /// standard 1.6 points/minute = 4 * 15 * 1.6 = 96.
    func test_scrollOffset_notSplit_offsetsFromVisibleRangeStart() {
        let offset = DayTimelineGeometry.scrollToRoughlyNowOffset(
            twoMinuteSectionHeight: 50,
            amSectionHeight: 70,
            isSplitAtNoon: false,
            targetQuarter: 32,          // 8am
            middaySplitQuarter: 48,     // noon — ignored when not split
            morningDayHeight: 1200,     // ignored when not split
            middaySectionHeight: 90,    // ignored when not split
            afternoonRangeStart: 48,    // ignored when not split
            rangeStart: 28,             // 7am
            pointsPerMinute: 1.6
        )

        XCTAssertEqual(offset, 120 + 96)
    }

    /// Split, but the target is still before the split — takes the same
    /// branch as an unsplit day, offsetting from the *morning* range.
    func test_scrollOffset_splitButTargetBeforeSplit_usesMorningBranch() {
        let offset = DayTimelineGeometry.scrollToRoughlyNowOffset(
            twoMinuteSectionHeight: 50,
            amSectionHeight: 70,
            isSplitAtNoon: true,
            targetQuarter: 32,          // 8am, before the noon split
            middaySplitQuarter: 48,
            morningDayHeight: 1200,
            middaySectionHeight: 90,
            afternoonRangeStart: 48,
            rangeStart: 28,
            pointsPerMinute: 1.6
        )

        XCTAssertEqual(offset, 120 + 96, "must not add the morning grid or midday section for a pre-split target")
    }

    /// Fail-then-pass target. Split, target past the split: the offset
    /// must clear the header, the entire morning grid, and the midday
    /// section before offsetting within the afternoon range.
    /// 2 quarters past the afternoon start = 2 * 15 * 1.6 = 48.
    func test_scrollOffset_splitAndTargetPastSplit_clearsMorningGridAndMidday() {
        let offset = DayTimelineGeometry.scrollToRoughlyNowOffset(
            twoMinuteSectionHeight: 50,
            amSectionHeight: 70,
            isSplitAtNoon: true,
            targetQuarter: 50,          // 12:30pm, past the noon split
            middaySplitQuarter: 48,
            morningDayHeight: 1200,
            middaySectionHeight: 90,
            afternoonRangeStart: 48,
            rangeStart: 28,
            pointsPerMinute: 1.6
        )

        XCTAssertEqual(offset, 120 + 1200 + 90 + 48)
    }

    /// The boundary itself belongs to the afternoon branch (`>=`, not
    /// `>`) — a target landing exactly on the split must scroll to the
    /// afternoon segment, not to the bottom of the morning one.
    func test_scrollOffset_targetExactlyOnSplit_takesAfternoonBranch() {
        let offset = DayTimelineGeometry.scrollToRoughlyNowOffset(
            twoMinuteSectionHeight: 0,
            amSectionHeight: 0,
            isSplitAtNoon: true,
            targetQuarter: 48,
            middaySplitQuarter: 48,
            morningDayHeight: 1000,
            middaySectionHeight: 60,
            afternoonRangeStart: 48,
            rangeStart: 28,
            pointsPerMinute: 1.6
        )

        XCTAssertEqual(offset, 1060, "exactly at the split is an afternoon target")
    }

    /// The header terms feed the scroll offset through the same
    /// `precedingContentHeight` the segments use — so the two can't drift
    /// apart into separate notions of "how far down the content starts."
    func test_scrollOffset_headerMatchesPrecedingContentHeight() {
        let header = DayTimelineGeometry.precedingContentHeight(
            twoMinuteSectionHeight: 33, amSectionHeight: 44
        )
        // A target sitting exactly on the range start contributes no
        // quarter-distance, leaving the header as the whole offset.
        let offset = DayTimelineGeometry.scrollToRoughlyNowOffset(
            twoMinuteSectionHeight: 33,
            amSectionHeight: 44,
            isSplitAtNoon: false,
            targetQuarter: 28,
            middaySplitQuarter: 48,
            morningDayHeight: 0,
            middaySectionHeight: 0,
            afternoonRangeStart: 48,
            rangeStart: 28,
            pointsPerMinute: 1.6
        )

        XCTAssertEqual(offset, header)
    }
}
