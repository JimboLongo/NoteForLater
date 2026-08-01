import Foundation

/// Reads free/busy info from Google Calendar so the scheduler knows which
/// windows on a given day are actually open.
protocol CalendarServiceProtocol: AnyObject {
    /// Working hours to constrain scheduling to (e.g. 8am-9pm). Exposed so the
    /// UI can let the user configure it later.
    var workingHours: (start: DateComponents, end: DateComponents) { get set }

    /// Google calendar IDs (e.g. "primary", or another calendar's ID) whose
    /// events count as "busy". Populated from the user's enabled
    /// CalendarSubscription rows before generating a schedule.
    var enabledCalendarIDs: [String] { get set }

    /// Returns the open time slots for `date`, after subtracting existing
    /// calendar events and respecting `workingHours`.
    func fetchFreeSlots(for date: Date) async throws -> [TimeSlot]

    /// Returns the existing "busy" ranges on `date` (within `workingHours`)
    /// from the enabled calendars, so the Schedule tab can show what's
    /// already blocked off alongside proposed task blocks.
    func fetchBusyBlocks(for date: Date) async throws -> [TimeSlot]

    /// Writes an approved ScheduledBlock to the user's primary Google Calendar
    /// as a real event, so it shows up alongside everything else.
    func createEvent(for block: ScheduledBlock) async throws
}

struct GoogleCalendarSummary: Identifiable {
    let id: String
    let name: String
    let isPrimary: Bool
}

enum GoogleCalendarError: LocalizedError {
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .requestFailed(let status):
            return "Google Calendar request failed (status \(status))."
        }
    }
}

/// Real implementation, backed by the Calendar API v3 REST endpoints
/// (freeBusy, calendarList, events.insert) using the signed-in account's
/// OAuth token.
final class GoogleCalendarService: CalendarServiceProtocol {
    private let accountService: GoogleAccountServiceProtocol

    var workingHours: (start: DateComponents, end: DateComponents) = (
        DateComponents(hour: 8, minute: 0),
        DateComponents(hour: 21, minute: 0)
    )
    var enabledCalendarIDs: [String] = ["primary"]

    init(accountService: GoogleAccountServiceProtocol = GoogleAccountService.shared) {
        self.accountService = accountService
    }

    func fetchFreeSlots(for date: Date) async throws -> [TimeSlot] {
        let (dayStart, dayEnd) = workingHoursRange(for: date)
        let busy = try await fetchBusyRanges(from: dayStart, to: dayEnd)

        var freeSlots: [TimeSlot] = []
        var cursor = dayStart
        for range in busy.sorted(by: { $0.start < $1.start }) {
            if range.start > cursor {
                freeSlots.append(TimeSlot(start: cursor, end: range.start))
            }
            cursor = max(cursor, range.end)
        }
        if cursor < dayEnd {
            freeSlots.append(TimeSlot(start: cursor, end: dayEnd))
        }
        return freeSlots
    }

    func fetchBusyBlocks(for date: Date) async throws -> [TimeSlot] {
        let (dayStart, dayEnd) = workingHoursRange(for: date)
        return try await fetchBusyRanges(from: dayStart, to: dayEnd)
            .sorted { $0.start < $1.start }
    }

    private func workingHoursRange(for date: Date) -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let dayStart = calendar.date(
            bySettingHour: workingHours.start.hour ?? 8,
            minute: workingHours.start.minute ?? 0,
            second: 0, of: date
        )!
        let dayEnd = calendar.date(
            bySettingHour: workingHours.end.hour ?? 21,
            minute: workingHours.end.minute ?? 0,
            second: 0, of: date
        )!
        return (dayStart, dayEnd)
    }

    func createEvent(for block: ScheduledBlock) async throws {
        let token = try await accountService.accessToken()
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let formatter = ISO8601DateFormatter()
        let body: [String: Any] = [
            "summary": block.task?.title ?? "Scheduled task",
            "start": ["dateTime": formatter.string(from: block.startTime)],
            "end": ["dateTime": formatter.string(from: block.endTime)]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        try Self.checkOK(response)
    }

    /// Calendars in the user's Google Calendar list, so Settings can let
    /// them choose which ones count toward "don't schedule over this".
    func fetchCalendarList() async throws -> [GoogleCalendarSummary] {
        let token = try await accountService.accessToken()
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkOK(response)
        let decoded = try JSONDecoder().decode(CalendarListResponse.self, from: data)
        return decoded.items.map { GoogleCalendarSummary(id: $0.id, name: $0.summary, isPrimary: $0.primary ?? false) }
    }

    private func fetchBusyRanges(from start: Date, to end: Date) async throws -> [TimeSlot] {
        guard !enabledCalendarIDs.isEmpty else { return [] }

        let token = try await accountService.accessToken()
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/calendar/v3/freeBusy")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let formatter = ISO8601DateFormatter()
        let body: [String: Any] = [
            "timeMin": formatter.string(from: start),
            "timeMax": formatter.string(from: end),
            "items": enabledCalendarIDs.map { ["id": $0] }
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkOK(response)
        let decoded = try JSONDecoder().decode(FreeBusyResponse.self, from: data)
        return decoded.calendars.values.flatMap { calendar in
            calendar.busy.compactMap { range -> TimeSlot? in
                guard let s = formatter.date(from: range.start), let e = formatter.date(from: range.end) else { return nil }
                return TimeSlot(start: s, end: e)
            }
        }
    }

    private static func checkOK(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw GoogleCalendarError.requestFailed(status)
        }
    }

    private struct CalendarListResponse: Decodable {
        struct Item: Decodable {
            let id: String
            let summary: String
            let primary: Bool?
        }
        let items: [Item]
    }

    private struct FreeBusyResponse: Decodable {
        struct CalendarBusy: Decodable {
            struct Range: Decodable { let start: String; let end: String }
            let busy: [Range]
        }
        let calendars: [String: CalendarBusy]
    }
}

/// Kept around for SwiftUI Previews so they don't need real credentials or
/// network access to render.
final class MockCalendarService: CalendarServiceProtocol {
    var workingHours: (start: DateComponents, end: DateComponents) = (
        DateComponents(hour: 8, minute: 0),
        DateComponents(hour: 21, minute: 0)
    )
    var enabledCalendarIDs: [String] = ["primary"]

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

        let busy = try await fetchBusyBlocks(for: date)

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

    func fetchBusyBlocks(for date: Date) async throws -> [TimeSlot] {
        let calendar = Calendar.current
        return mockBusyRanges.map { range -> TimeSlot in
            let start = calendar.date(bySettingHour: range.start.hour ?? 0,
                                       minute: range.start.minute ?? 0,
                                       second: 0, of: date)!
            let end = calendar.date(bySettingHour: range.end.hour ?? 0,
                                     minute: range.end.minute ?? 0,
                                     second: 0, of: date)!
            return TimeSlot(start: start, end: end)
        }.sorted { $0.start < $1.start }
    }

    func createEvent(for block: ScheduledBlock) async throws {
        print("[MockCalendarService] would create event for \(block.task?.title ?? "untitled") at \(block.startTime)")
    }
}
