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
    static let clientID = "1058526752623-19qb8of0ut7hhdam0rkrta8e40gd20fa.apps.googleusercontent.com"

    /// The reversed Client ID, used as the custom URL scheme
    /// ASWebAuthenticationSession watches for on redirect.
    static let redirectScheme = "com.googleusercontent.apps.1058526752623-19qb8of0ut7hhdam0rkrta8e40gd20fa"

    static var redirectURI: String { "\(redirectScheme):/oauth2redirect" }

    // gmail.readonly is deliberately left out for now — the Gmail sync
    // feature (Services/GmailService.swift, InboxViewModel.syncGmail) is
    // built but not wired into any UI yet. Add it back here (and the
    // "Sync Unread Gmail" toolbar action in InboxView) to re-enable.
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
