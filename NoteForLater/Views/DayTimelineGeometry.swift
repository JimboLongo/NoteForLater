import Foundation

/// The day calendar's scroll-space arithmetic, pulled out of
/// `DayTimelineGridView` as plain functions over plain numbers.
///
/// **Why this exists as its own type:** these sums translate a grid-local
/// touch into the shared `ScrollView`'s content space — they are what
/// makes a dragged block land on the time it was released over (see
/// `DayTimelineSegment.precedingContentHeight` and its two drag/scroll
/// call sites). That made them the highest-risk, least-covered part of
/// the view: before this extraction no test referenced
/// `precedingContentHeight`, `amSectionHeight`, or the
/// `scrollToRoughlyNow` offset at all, so a mistake in the arithmetic
/// had nothing to fail against.
///
/// Extracted verbatim — every expression here is the same sum that was
/// previously written inline at its call site, in the same order, with
/// no rounding or clamping added. The point is to make the seam
/// *testable*, not to change it; `DayTimelineGeometryTests` pins each
/// one so the structural split of `DayTimelineGridView` has a
/// regression net under the part of it that no other test covers.
enum DayTimelineGeometry {
    /// Content sitting above the morning segment (or above the single
    /// continuous segment, when the day isn't split at noon): the
    /// 2-Minute checklist plus the Morning Habits section.
    static func precedingContentHeight(
        twoMinuteSectionHeight: CGFloat,
        amSectionHeight: CGFloat
    ) -> CGFloat {
        twoMinuteSectionHeight + amSectionHeight
    }

    /// Content above the *afternoon* segment on a split day — everything
    /// above the morning segment, plus the morning segment's own rendered
    /// height, plus the Midday Habits section wedged between them.
    ///
    /// `middaySectionHeight` is measured *including* that section's own
    /// `.padding(.vertical, 14)`, because the call site applies the
    /// padding before `.onGeometryChange` reads the height. Moving that
    /// padding inside the section view would silently shrink this sum by
    /// 28pt and shift every afternoon drop target.
    static func afternoonPrecedingContentHeight(
        twoMinuteSectionHeight: CGFloat,
        amSectionHeight: CGFloat,
        morningDayHeight: CGFloat,
        middaySectionHeight: CGFloat
    ) -> CGFloat {
        twoMinuteSectionHeight + amSectionHeight + morningDayHeight + middaySectionHeight
    }

    /// Where `scrollToRoughlyNow` should land, in the shared ScrollView's
    /// content space. Picks the afternoon segment (and adds its cumulative
    /// offset) when the day is split and the target time falls past the
    /// split; otherwise offsets within whichever single range is showing.
    ///
    /// `rangeStart` is the *caller's* already-chosen range start — the
    /// morning range on a split day, the whole visible range otherwise —
    /// kept as a parameter rather than re-derived here so this function
    /// stays a pure sum and the range choice stays where it already lives.
    static func scrollToRoughlyNowOffset(
        twoMinuteSectionHeight: CGFloat,
        amSectionHeight: CGFloat,
        isSplitAtNoon: Bool,
        targetQuarter: Int,
        middaySplitQuarter: Int,
        morningDayHeight: CGFloat,
        middaySectionHeight: CGFloat,
        afternoonRangeStart: Int,
        rangeStart: Int,
        pointsPerMinute: CGFloat
    ) -> CGFloat {
        let headerHeight = precedingContentHeight(
            twoMinuteSectionHeight: twoMinuteSectionHeight,
            amSectionHeight: amSectionHeight
        )
        if isSplitAtNoon, targetQuarter >= middaySplitQuarter {
            return headerHeight + morningDayHeight + middaySectionHeight
                + CGFloat(targetQuarter - afternoonRangeStart) * 15 * pointsPerMinute
        }
        return headerHeight + CGFloat(targetQuarter - rangeStart) * 15 * pointsPerMinute
    }
}
