import Foundation

struct GmailMessageSummary {
    let id: String
    let subject: String
    let snippet: String
}

enum GmailServiceError: LocalizedError {
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .requestFailed(let status):
            return "Gmail request failed (status \(status))."
        }
    }
}

protocol GmailServiceProtocol: AnyObject {
    /// Every unread message currently sitting in the inbox (not archived,
    /// not spam/trash), newest first, capped at a reasonable page size.
    func fetchUnreadInboxMessages() async throws -> [GmailMessageSummary]
}

/// Real implementation backed by the Gmail API v3 REST endpoints
/// (messages.list + messages.get) using the signed-in account's OAuth token.
final class GoogleGmailService: GmailServiceProtocol {
    private let accountService: GoogleAccountServiceProtocol
    private let maxResults: Int

    init(accountService: GoogleAccountServiceProtocol = GoogleAccountService.shared, maxResults: Int = 50) {
        self.accountService = accountService
        self.maxResults = maxResults
    }

    func fetchUnreadInboxMessages() async throws -> [GmailMessageSummary] {
        let token = try await accountService.accessToken()
        let ids = try await listUnreadMessageIDs(token: token)

        var summaries: [GmailMessageSummary] = []
        for id in ids {
            if let summary = try? await fetchMessageSummary(id: id, token: token) {
                summaries.append(summary)
            }
        }
        return summaries
    }

    private func listUnreadMessageIDs(token: String) async throws -> [String] {
        var components = URLComponents(string: "https://www.googleapis.com/gmail/v1/users/me/messages")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "is:unread in:inbox"),
            URLQueryItem(name: "maxResults", value: String(maxResults))
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkOK(response)
        let decoded = try JSONDecoder().decode(MessageListResponse.self, from: data)
        return decoded.messages?.map(\.id) ?? []
    }

    private func fetchMessageSummary(id: String, token: String) async throws -> GmailMessageSummary {
        var components = URLComponents(string: "https://www.googleapis.com/gmail/v1/users/me/messages/\(id)")!
        components.queryItems = [
            URLQueryItem(name: "format", value: "metadata"),
            URLQueryItem(name: "metadataHeaders", value: "Subject")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.checkOK(response)
        let decoded = try JSONDecoder().decode(MessageDetailResponse.self, from: data)
        let subject = decoded.payload?.headers?.first { $0.name.caseInsensitiveCompare("Subject") == .orderedSame }?.value
        return GmailMessageSummary(id: decoded.id, subject: subject ?? "", snippet: decoded.snippet ?? "")
    }

    private static func checkOK(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw GmailServiceError.requestFailed((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    private struct MessageListResponse: Decodable {
        struct MessageRef: Decodable { let id: String }
        let messages: [MessageRef]?
    }

    private struct MessageDetailResponse: Decodable {
        struct Payload: Decodable {
            struct Header: Decodable { let name: String; let value: String }
            let headers: [Header]?
        }
        let id: String
        let snippet: String?
        let payload: Payload?
    }
}

/// Kept around for SwiftUI Previews so they don't need real credentials or
/// network access to render.
final class MockGmailService: GmailServiceProtocol {
    func fetchUnreadInboxMessages() async throws -> [GmailMessageSummary] {
        [
            GmailMessageSummary(id: "mock-1", subject: "Team standup notes", snippet: "Here's what we covered..."),
            GmailMessageSummary(id: "mock-2", subject: "Invoice #4521 due", snippet: "Your invoice is ready...")
        ]
    }
}
