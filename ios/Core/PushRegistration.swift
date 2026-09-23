import Foundation
import UIKit
import UserNotifications

@MainActor
final class PushRegistration {
    static let shared = PushRegistration()

    func requestAuthorizationAndRegister() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        if granted { UserDefaults.standard.set(true, forKey: "pushRequested"); UIApplication.shared.registerForRemoteNotifications() }
        return granted
    }

    func uploadDeviceToken(_ data: Data) async {
        let token = data.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: "apnsDeviceToken")
        await upload(path: "v1/devices", body: ["token": token, "platform": "ios", "environment": pushEnvironment])
    }

    func uploadLiveActivityToken(_ token: String, activityID: String, operationID: String) async {
        await upload(path: "v1/live-activities/tokens", body: ["token": token, "activityId": activityID, "operationId": operationID, "environment": pushEnvironment])
    }

    private var pushEnvironment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }

    private func upload(path: String, body: [String: String]) async {
        let defaults = UserDefaults.standard
        guard let base = URL(string: defaults.string(forKey: "proxyURL") ?? ""),
              let userID = defaults.string(forKey: "opaqueUserID"), !userID.isEmpty else { return }
        var request = URLRequest(url: base.appending(path: path)); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userID, forHTTPHeaderField: "X-User-ID")
        if let token = KeychainStore.readProxyToken(), !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: request)
    }
}
