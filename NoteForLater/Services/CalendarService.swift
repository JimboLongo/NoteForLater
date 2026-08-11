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

    /// Same idea as fetchBusyBlocks, but with the real event title/notes
    /// (via events.list) instead of just a time range, so the Schedule tab
    /// can show what each blocked-off period actually is.
    func fetchEvents(for date: Date) async throws -> [CalendarEventSummary]

    /// Creates the event if `block.googleEventID` is nil, otherwise updates
    /// that same event in place — so re-approving an edited block overwrites
    /// what's already on the calendar instead of duplicating it. Returns the
    /// event ID either way.
    func pushEvent(for block: ScheduledBlock) async throws -> String

    /// Removes a previously-pushed event (e.g. its block was deleted).
    func deleteEvent(eventID: String) async throws

    /// Edits a synced calendar event in place (title/time/notes) and pushes
    /// the change back to Google.
    func updateEvent(eventID: String, title: String, start: Date, end: Date, notes: String?) async throws
}

struct GoogleCalendarSummary: Identifiable {
    let id: String
    let name: String
    let isPrimary: Bool
}

struct CalendarEventSummary: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let notes: String?
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
/// (freeBusy, calendarList, events.list, events.insert/patch/delete) using
/// the signed-in account's OAuth token.
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

    func fetchEvents(for date: Date) async throws -> [CalendarEventSummary] {
        guard !enabledCalendarIDs.isEmpty else { return [] }
        let (dayStart, dayEnd) = workingHoursRange(for: date)
        let token = try await accountService.accessToken()
        let formatter = ISO8601DateFormatter()

        var allEvents: [CalendarEventSummary] = []
        for calendarID in enabledCalendarIDs {
            let encodedID = calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarID
            var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedID)/events")!
            components.queryItems = [
                URLQueryItem(name: "timeMin", value: formatter.string(from: dayStart)),
                URLQueryItem(name: "timeMax", value: formatter.string(from: dayEnd)),
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "orderBy", value: "startTime")
            ]
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.checkOK(response)
            let decoded = try JSONDecoder().decode(EventsListResponse.self, from: data)
            let events = decoded.items.compactMap { item -> CalendarEventSummary? in
                guard
                    let startRaw = item.start?.dateTime ?? item.start?.date,
                    let endRaw = item.end?.dateTime ?? item.end?.date,
                    let start = formatter.date(from: startRaw) ?? Self.dateOnlyFormatter.date(from: startRaw),
                    let end = formatter.date(from: endRaw) ?? Self.dateOnlyFormatter.date(from: endRaw)
                else { return nil }
                return CalendarEventSummary(id: item.id, title: item.summary ?? "(No title)", start: start, end: end, notes: item.description)
            }
            allEvents.append(contentsOf: events)
        }
        return allEvents.sorted { $0.start < $1.start }
    }

    func pushEvent(for block: ScheduledBlock) async throws -> String {
        let token = try await accountService.accessToken()
        let formatter = ISO8601DateFormatter()
        let body: [String: Any] = [
            "summary": block.displayTitle,
            "start": ["dateTime": formatter.string(from: block.startTime)],
            "end": ["dateTime": formatter.string(from: block.endTime)]
        ]

        var request: URLRequest
        if let eventID = block.googleEventID {
            let encodedID = eventID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventID
            request = URLRequest(url: URL(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events/\(encodedID)")!)
            request.httpMethod = "PATCH"
        } else {
            request = URLRequest(url: URL(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!)
            request.httpMethod = "POST"
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkOK(response)
        return try JSONDecoder().decode(EventIDResponse.self, from: data).id
    }

    func deleteEvent(eventID: String) async throws {
        let token = try await accountService.accessToken()
        let encodedID = eventID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventID
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events/\(encodedID)")!)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)
        // 410 Gone means it's already not there — fine, that's the goal anyway.
        if let http = response as? HTTPURLResponse, http.statusCode == 410 { return }
        try Self.checkOK(response)
    }

    func updateEvent(eventID: String, title: String, start: Date, end: Date, notes: String?) async throws {
        let token = try await accountService.accessToken()
        let formatter = ISO8601DateFormatter()
        var body: [String: Any] = [
            "summary": title,
            "start": ["dateTime": formatter.string(from: start)],
            "end": ["dateTime": formatter.string(from: end)]
        ]
        if let notes { body["description"] = notes }

        let encodedID = eventID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? eventID
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events/\(encodedID)")!)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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

    private static func checkOK(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw GoogleCalendarError.requestFailed(status)
        }
    }

    private static let dateOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()

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

    private struct EventsListResponse: Decodable {
        struct EventDateTime: Decodable {
            let dateTime: String?
            let date: String?
        }
        struct Item: Decodable {
            let id: String
            let summary: String?
            let description: String?
            let start: EventDateTime?
            let end: EventDateTime?
        }
        let items: [Item]
    }

    private struct EventIDResponse: Decodable {
        let id: String
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
    var mockBusyRanges: [(start: DateComponents, end: DateComponents, title: String)] = [
        (DateComponents(hour: 9, minute: 0), DateComponents(hour: 10, minute: 0), "Standup"),
        (DateComponents(hour: 12, minute: 0), DateComponents(hour: 13, minute: 0), "Lunch"),
        (DateComponents(hour: 15, minute: 30), DateComponents(hour: 16, minute: 30), "1:1")
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

    func fetchEvents(for date: Date) async throws -> [CalendarEventSummary] {
        let calendar = Calendar.current
        return mockBusyRanges.map { range -> CalendarEventSummary in
            let start = calendar.date(bySettingHour: range.start.hour ?? 0,
                                       minute: range.start.minute ?? 0,
                                       second: 0, of: date)!
            let end = calendar.date(bySettingHour: range.end.hour ?? 0,
                                     minute: range.end.minute ?? 0,
                                     second: 0, of: date)!
            return CalendarEventSummary(id: UUID().uuidString, title: range.title, start: start, end: end, notes: nil)
        }.sorted { $0.start < $1.start }
    }

    func pushEvent(for block: ScheduledBlock) async throws -> String {
        print("[MockCalendarService] would push event for \(block.displayTitle) at \(block.startTime)")
        return block.googleEventID ?? UUID().uuidString
    }

    func deleteEvent(eventID: String) async throws {
        print("[MockCalendarService] would delete event \(eventID)")
    }

    func updateEvent(eventID: String, title: String, start: Date, end: Date, notes: String?) async throws {
        print("[MockCalendarService] would update event \(eventID) to \(title) at \(start)")
    }
}
