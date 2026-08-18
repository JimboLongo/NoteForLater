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
    var busyBlocksToReturn: [TimeSlot] = []
    var eventsToReturn: [CalendarEventSummary] = []
    private(set) var deletedEventIDs: [String] = []

    func fetchFreeSlots(for date: Date) async throws -> [TimeSlot] { freeSlotsToReturn }
    func fetchBusyBlocks(for date: Date) async throws -> [TimeSlot] { busyBlocksToReturn }
    func fetchEvents(for date: Date) async throws -> [CalendarEventSummary] { eventsToReturn }
    func pushEvent(for block: ScheduledBlock) async throws -> String { "fake-event-id" }
    func deleteEvent(eventID: String) async throws { deletedEventIDs.append(eventID) }
    func updateEvent(eventID: String, title: String, start: Date, end: Date, notes: String?) async throws {}
}
