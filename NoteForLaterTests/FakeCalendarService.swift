import Foundation
@testable import NoteForLater

/// Minimal `CalendarServiceProtocol` stub for tests that need to construct
/// a `ScheduleReviewViewModel` without hitting the real Google Calendar
/// service. `fetchFreeSlots`/`fetchBusyBlocks`/`fetchEvents` return
/// whatever's configured (empty by default); `pushEvent`/`deleteEvent`/
/// `updateEvent` are no-ops that just record they were called.
final class FakeCalendarService: CalendarServiceProtocol {
    var workingHours: (start: DateComponents, end: DateComponents) = (
        DateComponents(hour: 0, minute: 0),
        DateComponents(hour: 23, minute: 59)
    )
    var enabledCalendarIDs: [String] = ["primary"]

    var freeSlotsToReturn: [TimeSlot] = []
    /// Overrides `freeSlotsToReturn` with slots built for whichever day is
    /// actually being asked about. `freeSlotsToReturn` is a single fixed
    /// array reused for every date, which is fine when a test only cares
    /// about one day or expects nothing to place — but a multi-day walk
    /// that needs real placements on later days gets slots anchored to the
    /// wrong date, and the packer discards them. Set this instead in that
    /// case.
    var freeSlotsProvider: ((Date) -> [TimeSlot])?
    var busyBlocksToReturn: [TimeSlot] = []
    var eventsToReturn: [CalendarEventSummary] = []
    private(set) var deletedEventIDs: [String] = []
    /// Calls to the **single-day** `fetchFreeSlots(for:)` only. Since
    /// `ScheduleReviewViewModel`'s walks pre-fetch a ranged batch up
    /// front, this now measures *fallback* usage specifically — a walk
    /// that stays inside the pre-fetched window should leave this at 0,
    /// and anything above 0 means the walk ran past that window.
    private(set) var fetchFreeSlotsCallCount = 0
    /// Calls to the ranged `fetchFreeSlots(from:to:)`. The whole point of
    /// batching is that a walk makes exactly one of these regardless of
    /// how many days it visits.
    private(set) var fetchFreeSlotsRangedCallCount = 0
    /// The span the last ranged call actually asked for, so a test can
    /// assert the pre-fetch window itself rather than just that some call
    /// happened.
    private(set) var lastRangedRequest: (start: Date, end: Date)?

    func fetchFreeSlots(for date: Date) async throws -> [TimeSlot] {
        fetchFreeSlotsCallCount += 1
        return freeSlotsProvider?(date) ?? freeSlotsToReturn
    }

    /// Serves the same fixed `freeSlotsToReturn` for every day in the
    /// span — matching what the single-day method above already does for
    /// any date it's handed, so batching doesn't change what a test sees
    /// per day, only how many calls it took to get there.
    func fetchFreeSlots(from start: Date, to end: Date) async throws -> [Date: [TimeSlot]] {
        fetchFreeSlotsRangedCallCount += 1
        lastRangedRequest = (start, end)
        var result: [Date: [TimeSlot]] = [:]
        for day in calendarDays(from: start, to: end) {
            result[day] = freeSlotsProvider?(day) ?? freeSlotsToReturn
        }
        return result
    }
    func fetchBusyBlocks(for date: Date) async throws -> [TimeSlot] { busyBlocksToReturn }
    func fetchEvents(for date: Date) async throws -> [CalendarEventSummary] { eventsToReturn }
    func pushEvent(for block: ScheduledBlock) async throws -> String { "fake-event-id" }
    func deleteEvent(eventID: String) async throws { deletedEventIDs.append(eventID) }
    func updateEvent(eventID: String, title: String, start: Date, end: Date, notes: String?) async throws {}
}
