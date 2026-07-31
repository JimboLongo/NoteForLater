import Foundation

/// Fill these in from your own Google Cloud Console OAuth client:
///
///   1. https://console.cloud.google.com/apis/credentials — create a project
///      (or use an existing one) and enable the "Google Calendar API" under
///      APIs & Services > Library.
///   2. APIs & Services > Credentials > Create Credentials > OAuth client ID
///      > Application type "iOS". Bundle ID must match this app's
///      (com.jimbo.NoteForLater).
///   3. Google shows you a Client ID and an "iOS URL scheme" (the reversed
///      client ID). Paste the Client ID below, and the URL scheme into
///      `redirectScheme`.
///
/// No client secret is needed — this uses the Authorization Code + PKCE
/// flow for native apps, so the client is public.
enum GoogleOAuthConfig {
    /// e.g. "1234567890-abcdefghijklmnop.apps.googleusercontent.com"
    static let clientID = "YOUR_CLIENT_ID.apps.googleusercontent.com"

    /// The "iOS URL scheme" Google shows you for this client, e.g.
    /// "com.googleusercontent.apps.1234567890-abcdefghijklmnop".
    static let redirectScheme = "com.googleusercontent.apps.YOUR_CLIENT_ID"

    static var redirectURI: String { "\(redirectScheme):/oauth2redirect" }

    static let scopes = [
        "https://www.googleapis.com/auth/calendar.readonly",
        "https://www.googleapis.com/auth/calendar.events",
        "https://www.googleapis.com/auth/userinfo.email",
        "openid"
    ]

    static var isConfigured: Bool {
        !clientID.hasPrefix("YOUR_CLIENT_ID") && !redirectScheme.hasSuffix("YOUR_CLIENT_ID")
    }
}
