import Foundation

/// Represents the signed-in Google identity used to authorize Calendar/Gmail access.
struct GoogleAccount: Equatable {
    let email: String
    let displayName: String
}

/// Handles Google Sign-In and holds the OAuth token used by CalendarService/GmailService.
///
/// TODO(Claude Code): Replace this mock with the real GoogleSignIn SDK flow:
///   1. Add the GoogleSignIn-iOS package (https://github.com/google/GoogleSignIn-iOS).
///   2. Register the app in Google Cloud Console, enable the Calendar API and Gmail API,
///      and add the reversed client ID as a URL scheme in Info.plist.
///   3. Request scopes:
///        https://www.googleapis.com/auth/calendar.readonly (free/busy + events)
///        https://www.googleapis.com/auth/calendar.events (to write approved blocks back)
///        https://www.googleapis.com/auth/gmail.readonly (only if/when inbox pulls from email)
///   4. Store the resulting access/refresh token in Keychain, not UserDefaults.
protocol GoogleAccountServiceProtocol: AnyObject {
    var currentAccount: GoogleAccount? { get }
    func signIn() async throws -> GoogleAccount
    func signOut()
    /// A valid OAuth access token, refreshing under the hood if needed.
    func accessToken() async throws -> String
}

final class MockGoogleAccountService: GoogleAccountServiceProtocol {
    private(set) var currentAccount: GoogleAccount?

    func signIn() async throws -> GoogleAccount {
        let account = GoogleAccount(email: "jimmylong603@gmail.com", displayName: "Jimbo")
        currentAccount = account
        return account
    }

    func signOut() {
        currentAccount = nil
    }

    func accessToken() async throws -> String {
        "mock-access-token"
    }
}
