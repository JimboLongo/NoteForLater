import Foundation

/// Reads free/busy info from Google Calendar so the scheduler knows which
/// windows on a given day are actually open.
///
/// TODO(Claude Code): Implement against the real Calendar API:
///   GET https://www.googleapis.com/calendar/v3/freeBusy (POST body with timeMin/timeMax)
///   using the token from GoogleAccountServiceProtocol.accessToken(). Map the
///   returned busy[] ranges into the complement (free) windows within the
///   user's working hours (see workingHours below).
protocol CalendarServiceProtocol: AnyObject {
    /// Working hours to constrain scheduling to (e.g. 8am-9pm). Exposed so the
    /// UI can let the user configure it later.
    var workingHours: (start: DateComponents, end: DateComponents) { get set }

    /// Returns the open time slots for `date`, after subtracting existing
    /// calendar events and respecting `workingHours`.
    func fetchFreeSlots(for date: Date) async throws -> [TimeSlot]

    /// Writes an approved ScheduledBlock to the user's primary Google Calendar
    /// as a real event, so it shows up alongside everything else.
    func createEvent(for block: ScheduledBlock) async throws
}

final class MockCalendarService: CalendarServiceProtocol {
    var workingHours: (start: DateComponents, end: DateComponents) = (
        DateComponents(hour: 8, minute: 0),
        DateComponents(hour: 21, minute: 0)
    )

    /// Stand-in "busy" events so the mock scheduler has something to work around.
    var mockBusyRanges: [(start: DateComponents, end: DateComponents)] = [
        (DateComponents(hour: 9, minute: 0), DateComponents(hour: 10, minute: 0)),
        (DateComponents(hour: 12, minute: 0), DateComponents(hour: 13, minute: 0)),
        (DateComponents(hour: 15, minute: 30), DateComponents(hour: 16, minute: 30))
    ]

    func fetchFreeSlots(for date: Date) async throws -> [TimeSlot] {
        let calendar = Calendar.current
        let dayStart = calendar.date(bySettingHour: workingHours.start.hour ?? 8,
                                      minute: workingHours.start.minute ?? 0,
                                      second: 0, of: date)!
        let dayEnd = calendar.date(bySettingHour: workingHours.end.hour ?? 21,
                                    minute: workingHours.end.minute ?? 0,
                                    second: 0, of: date)!

        let busy = mockBusyRanges.map { range -> TimeSlot in
            let start = calendar.date(bySettingHour: range.start.hour ?? 0,
                                       minute: range.start.minute ?? 0,
                                       second: 0, of: date)!
            let end = calendar.date(bySettingHour: range.end.hour ?? 0,
                                     minute: range.end.minute ?? 0,
                                     second: 0, of: date)!
            return TimeSlot(start: start, end: end)
        }.sorted { $0.start < $1.start }

        var freeSlots: [TimeSlot] = []
        var cursor = dayStart
        for busyRange in busy {
            if busyRange.start > cursor {
                freeSlots.append(TimeSlot(start: cursor, end: busyRange.start))
            }
            cursor = max(cursor, busyRange.end)
        }
        if cursor < dayEnd {
            freeSlots.append(TimeSlot(start: cursor, end: dayEnd))
        }
        return freeSlots
    }

    func createEvent(for block: ScheduledBlock) async throws {
        // No-op in the mock. Real implementation POSTs to
        // https://www.googleapis.com/calendar/v3/calendars/primary/events
        print("[MockCalendarService] would create event for \(block.task?.title ?? "untitled") at \(block.startTime)")
    }
}
