import Foundation
import AuthenticationServices
import CryptoKit
import UIKit

/// Represents the signed-in Google identity used to authorize Calendar/Gmail access.
struct GoogleAccount: Equatable {
    let email: String
    let displayName: String
}

enum GoogleAuthError: LocalizedError {
    case notConfigured
    case userCancelled
    case invalidCallback
    case tokenExchangeFailed
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Add your Google OAuth Client ID in GoogleOAuthConfig.swift first."
        case .userCancelled:
            return "Sign-in was cancelled."
        case .invalidCallback:
            return "Google's sign-in response was missing an authorization code."
        case .tokenExchangeFailed:
            return "Couldn't exchange the authorization code for a token."
        case .notSignedIn:
            return "Not signed in to Google."
        }
    }
}

/// Handles Google Sign-In and holds the OAuth token used by CalendarService/GmailService.
protocol GoogleAccountServiceProtocol: AnyObject {
    var currentAccount: GoogleAccount? { get }
    func signIn() async throws -> GoogleAccount
    func signOut()
    /// A valid OAuth access token, refreshing under the hood if needed.
    func accessToken() async throws -> String
}

/// Real implementation: Authorization Code + PKCE flow via
/// ASWebAuthenticationSession (no third-party SDK), REST token exchange,
/// tokens persisted in the Keychain. Requires GoogleOAuthConfig to be filled
/// in with a real Client ID from Google Cloud Console.
@Observable
final class GoogleAccountService: NSObject, GoogleAccountServiceProtocol {
    static let shared = GoogleAccountService()

    private(set) var currentAccount: GoogleAccount?

    private var storedAccessToken: String?
    private var refreshToken: String?
    private var expiresAt: Date?

    /// Must stay retained for the lifetime of the auth flow — ASWebAuthenticationSession
    /// doesn't hold a strong reference to itself.
    private var pendingAuthSession: ASWebAuthenticationSession?

    private override init() {
        super.init()
        if let stored = KeychainTokenStore.load() {
            currentAccount = GoogleAccount(email: stored.email, displayName: stored.displayName)
            storedAccessToken = stored.accessToken
            refreshToken = stored.refreshToken
            expiresAt = stored.expiresAt
        }
    }

    @MainActor
    func signIn() async throws -> GoogleAccount {
        guard GoogleOAuthConfig.isConfigured else { throw GoogleAuthError.notConfigured }

        let verifier = Self.randomPKCEVerifier()
        let challenge = Self.pkceChallenge(for: verifier)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: GoogleOAuthConfig.clientID),
            URLQueryItem(name: "redirect_uri", value: GoogleOAuthConfig.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: GoogleOAuthConfig.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]

        let callbackURL = try await authenticate(url: components.url!)

        guard
            let callbackComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
            let code = callbackComponents.queryItems?.first(where: { $0.name == "code" })?.value
        else {
            throw GoogleAuthError.invalidCallback
        }

        let tokens = try await exchangeCodeForTokens(code: code, verifier: verifier)
        let profile = try await fetchUserInfo(accessToken: tokens.accessToken)

        let account = GoogleAccount(email: profile.email, displayName: profile.name ?? profile.email)
        let newExpiresAt = Date().addingTimeInterval(TimeInterval(tokens.expiresIn))

        currentAccount = account
        storedAccessToken = tokens.accessToken
        refreshToken = tokens.refreshToken ?? refreshToken
        expiresAt = newExpiresAt

        KeychainTokenStore.save(StoredGoogleTokens(
            accessToken: tokens.accessToken,
            refreshToken: refreshToken,
            expiresAt: newExpiresAt,
            email: account.email,
            displayName: account.displayName
        ))

        return account
    }

    func signOut() {
        currentAccount = nil
        storedAccessToken = nil
        refreshToken = nil
        expiresAt = nil
        KeychainTokenStore.clear()
    }

    func accessToken() async throws -> String {
        guard let storedAccessToken else { throw GoogleAuthError.notSignedIn }
        if let expiresAt, expiresAt > Date().addingTimeInterval(60) {
            return storedAccessToken
        }
        guard let refreshToken else { throw GoogleAuthError.notSignedIn }

        let refreshed = try await refreshAccessToken(refreshToken: refreshToken)
        let newExpiresAt = Date().addingTimeInterval(TimeInterval(refreshed.expiresIn))
        self.storedAccessToken = refreshed.accessToken
        self.expiresAt = newExpiresAt

        if let currentAccount {
            KeychainTokenStore.save(StoredGoogleTokens(
                accessToken: refreshed.accessToken,
                refreshToken: self.refreshToken,
                expiresAt: newExpiresAt,
                email: currentAccount.email,
                displayName: currentAccount.displayName
            ))
        }
        return refreshed.accessToken
    }

    // MARK: - ASWebAuthenticationSession

    @MainActor
    private func authenticate(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: GoogleOAuthConfig.redirectScheme
            ) { [weak self] callbackURL, error in
                self?.pendingAuthSession = nil
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let authError = error as? ASWebAuthenticationSessionError, authError.code == .canceledLogin {
                    continuation.resume(throwing: GoogleAuthError.userCancelled)
                } else {
                    continuation.resume(throwing: error ?? GoogleAuthError.invalidCallback)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            pendingAuthSession = session
            session.start()
        }
    }

    // MARK: - Token exchange

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    private struct UserInfo: Decodable {
        let email: String
        let name: String?
    }

    private func exchangeCodeForTokens(code: String, verifier: String) async throws -> TokenResponse {
        let params = [
            "code": code,
            "client_id": GoogleOAuthConfig.clientID,
            "redirect_uri": GoogleOAuthConfig.redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier
        ]
        return try await postForm(to: "https://oauth2.googleapis.com/token", params: params)
    }

    private func refreshAccessToken(refreshToken: String) async throws -> TokenResponse {
        let params = [
            "refresh_token": refreshToken,
            "client_id": GoogleOAuthConfig.clientID,
            "grant_type": "refresh_token"
        ]
        return try await postForm(to: "https://oauth2.googleapis.com/token", params: params)
    }

    private func postForm(to urlString: String, params: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(params)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw GoogleAuthError.tokenExchangeFailed
        }
        let decoder = JSONDecoder()
        return try decoder.decode(TokenResponse.self, from: data)
    }

    private func fetchUserInfo(accessToken: String) async throws -> UserInfo {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw GoogleAuthError.tokenExchangeFailed
        }
        return try JSONDecoder().decode(UserInfo.self, from: data)
    }

    private static func formEncode(_ params: [String: String]) -> Data {
        params.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&").data(using: .utf8)!
    }

    // MARK: - PKCE

    private static func randomPKCEVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private static func pkceChallenge(for verifier: String) -> String {
        let hashed = SHA256.hash(data: Data(verifier.utf8))
        return Data(hashed).base64URLEncodedString()
    }
}

extension GoogleAccountService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return allowed
    }()
}

/// Kept around for SwiftUI Previews, which shouldn't hit the network or
/// require real Google credentials to render.
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
