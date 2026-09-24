@preconcurrency import ActivityKit
import Foundation
import UIKit

@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()
    private var activity: Activity<DeepSeekActivityAttributes>?

    func start(id: String = UUID().uuidString, title: String, kind: String, detail: String) {
        guard UIApplication.shared.applicationState != .active,
              ActivityAuthorizationInfo().areActivitiesEnabled,
              activity == nil else { return }
        let attributes = DeepSeekActivityAttributes(operationID: id, title: title, kind: kind)
        let state = DeepSeekActivityAttributes.ContentState(phase: "running", detail: detail, progress: 0)
        activity = try? Activity.request(attributes: attributes, content: .init(state: state, staleDate: nil), pushType: .token)
        observePushToken()
    }

    func update(detail: String, progress: Double) async {
        let state = DeepSeekActivityAttributes.ContentState(phase: "running", detail: detail, progress: min(max(progress, 0), 1))
        guard let currentActivity = activity else { return }
        await currentActivity.update(.init(state: state, staleDate: nil))
    }

    func finish(detail: String, success: Bool) async {
        let state = DeepSeekActivityAttributes.ContentState(phase: success ? "completed" : "failed", detail: detail, progress: 1)
        guard let currentActivity = activity else { return }
        let policy: ActivityUIDismissalPolicy = UIApplication.shared.applicationState == .active ? .immediate : .default
        await currentActivity.end(.init(state: state, staleDate: nil), dismissalPolicy: policy)
        activity = nil
    }

    private func observePushToken() {
        guard let activity else { return }
        Task {
            for await token in activity.pushTokenUpdates {
                let value = token.map { String(format: "%02x", $0) }.joined()
                await PushRegistration.shared.uploadLiveActivityToken(value, activityID: activity.id, operationID: activity.attributes.operationID)
            }
        }
    }
}
