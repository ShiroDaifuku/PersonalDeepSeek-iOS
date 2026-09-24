import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        if UserDefaults.standard.bool(forKey: "pushRequested") { application.registerForRemoteNotifications() }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { await PushRegistration.shared.uploadDeviceToken(deviceToken) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let info = notification.request.content.userInfo
        if info["conversation_id"] != nil || info["conversationId"] != nil { return [] }
        return [.banner, .sound, .badge]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if let taskID = (info["task_id"] ?? info["taskId"]) as? String { UserDefaults.standard.set(taskID, forKey: "pendingTaskID") }
        if let conversationID = (info["conversation_id"] ?? info["conversationId"]) as? String { UserDefaults.standard.set(conversationID, forKey: "pendingConversationID") }
        NotificationCenter.default.post(name: .deepSeekNotificationRoute, object: nil, userInfo: info)
    }
}

extension Notification.Name { static let deepSeekNotificationRoute = Notification.Name("DeepSeekNotificationRoute") }
