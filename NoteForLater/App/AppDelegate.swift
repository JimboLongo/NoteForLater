import UIKit
import UserNotifications

/// Registers the Home Screen quick action and forwards a cold-launch tap on
/// it to QuickActionService. Warm-app taps are handled by SceneDelegate
/// instead. Also the app's UNUserNotificationCenterDelegate, so a tap on
/// the Nightly Review notification (see NightlyReviewNotificationService)
/// or a Daily Digest notification (see DailyDigestNotificationService) can
/// be routed to their respective launch states regardless of whether the
/// app was cold-launched, backgrounded, or already in the foreground.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        QuickActionService.registerShortcutItems()
        UNUserNotificationCenter.current().delegate = self
        if let shortcutItem = launchOptions?[.shortcutItem] as? UIApplicationShortcutItem {
            QuickActionService.shared.handle(shortcutItem)
        }
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

/// Catches the quick action when it's tapped while the app is already
/// running or suspended in the background (AppDelegate only sees cold launches).
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        QuickActionService.shared.handle(shortcutItem)
        completionHandler(true)
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.notification.request.identifier == NightlyReviewNotificationService.identifier {
            NightlyReviewLaunchState.shared.pendingReview = true
        } else if response.notification.request.identifier.hasPrefix(DailyDigestNotificationService.identifierPrefix) {
            DailyDigestLaunchState.shared.pendingCheckIn = true
        }
        completionHandler()
    }

    /// Without this, a notification is silently swallowed while the app is
    /// already in the foreground — fine for most reminders, but both the
    /// Nightly Review and Daily Digest notifications are meant as entry
    /// points into their own flows, so they still need to show as a
    /// banner even then.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
