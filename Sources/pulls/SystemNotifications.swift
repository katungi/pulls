import Foundation
import UserNotifications

/// System notification permission for a future UNUserNotificationCenter delivery path.
///
/// Pulls' development banners live in BannerPresenter and do not call this type.
/// Requesting permission is the only system-notification behavior in this phase.
/// Pull-request delivery is intentionally not implemented.
protocol SystemNotificationAuthorizing: Sendable {
    func requestAuthorization() async -> Bool
}

struct UserNotificationCenterAuthorizer: SystemNotificationAuthorizing {
    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if granted {
            PullsLog.notifications.info("System notification authorization granted")
        } else {
            PullsLog.notifications.info("System notification authorization denied")
        }
        return granted
    }
}
