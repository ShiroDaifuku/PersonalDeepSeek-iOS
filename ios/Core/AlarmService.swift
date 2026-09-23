import Foundation
import SwiftUI
#if canImport(AlarmKit)
import AlarmKit
#endif

enum DeviceAlarmError: LocalizedError {
    case unavailable, unauthorized, invalidSchedule
    var errorDescription: String? {
        switch self {
        case .unavailable: "强提醒需要 iOS 26 或更高版本。"
        case .unauthorized: "未获得强提醒权限。"
        case .invalidSchedule: "此任务计划无法转换为设备强提醒。"
        }
    }
}

struct AlarmDescriptor: Equatable {
    var id: UUID
    var title: String
    var hour: Int
    var minute: Int
    /// Calendar weekday values: 1 is Sunday, 7 is Saturday. Empty means one-shot at the next occurrence.
    var weekdays: [Int]
    var fixedDate: Date?
    var timezone: String
}

enum AlarmScheduleParser {
    static func parse(taskID: String, title: String, schedule: TaskSchedule) -> AlarmDescriptor? {
        let stableID = UUID(uuidString: taskID) ?? UUID()
        if schedule.type == "cron" {
            let fields = schedule.expression.split(separator: " ")
            guard fields.count == 5, let minute = Int(fields[0]), let hour = Int(fields[1]), (0...59).contains(minute), (0...23).contains(hour) else { return nil }
            let days: [Int]
            if fields[4] == "*" { days = Array(1...7) }
            else {
                let parsed = fields[4].split(separator: ",").compactMap { Int($0) }
                guard parsed.count == fields[4].split(separator: ",").count, parsed.allSatisfy({ (0...6).contains($0) }) else { return nil }
                days = parsed.map { $0 == 0 ? 1 : $0 + 1 }
            }
            return AlarmDescriptor(id: stableID, title: title, hour: hour, minute: minute, weekdays: days, fixedDate: nil, timezone: schedule.timezone)
        }
        if schedule.type == "once", let date = ISO8601DateFormatter().date(from: schedule.expression) {
            let values = Calendar.current.dateComponents([.hour, .minute], from: date)
            guard let hour = values.hour, let minute = values.minute else { return nil }
            return AlarmDescriptor(id: stableID, title: title, hour: hour, minute: minute, weekdays: [], fixedDate: date, timezone: schedule.timezone)
        }
        return nil
    }
}

@MainActor
final class DeviceAlarmService {
    static let shared = DeviceAlarmService()

    func schedule(_ descriptor: AlarmDescriptor) async throws {
        #if canImport(AlarmKit)
        if #available(iOS 26.1, *) {
            let state = try await AlarmManager.shared.requestAuthorization()
            guard state == .authorized else { throw DeviceAlarmError.unauthorized }
            let schedule: Alarm.Schedule
            if let date = descriptor.fixedDate { schedule = .fixed(date) }
            else {
                guard descriptor.timezone == TimeZone.current.identifier else { throw DeviceAlarmError.invalidSchedule }
                let time = Alarm.Schedule.Relative.Time(hour: descriptor.hour, minute: descriptor.minute)
                let weekdays = descriptor.weekdays.compactMap(localeWeekday)
                guard !weekdays.isEmpty else { throw DeviceAlarmError.invalidSchedule }
                schedule = .relative(.init(time: time, repeats: .weekly(weekdays)))
            }
            let alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: descriptor.title))
            let presentation = AlarmPresentation(alert: alert)
            let attributes = AlarmAttributes<PersonalAlarmMetadata>(presentation: presentation, metadata: .init(taskID: descriptor.id.uuidString), tintColor: .indigo)
            let configuration = AlarmManager.AlarmConfiguration.alarm(schedule: schedule, attributes: attributes)
            _ = try await AlarmManager.shared.schedule(id: descriptor.id, configuration: configuration)
            return
        }
        #endif
        throw DeviceAlarmError.unavailable
    }

    func cancel(id: UUID) throws {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) { try AlarmManager.shared.cancel(id: id); return }
        #endif
        throw DeviceAlarmError.unavailable
    }

    #if canImport(AlarmKit)
    @available(iOS 26.0, *)
    private func localeWeekday(_ value: Int) -> Locale.Weekday? {
        switch value { case 1: .sunday; case 2: .monday; case 3: .tuesday; case 4: .wednesday; case 5: .thursday; case 6: .friday; case 7: .saturday; default: nil }
    }

    @available(iOS 26.0, *)
    private struct PersonalAlarmMetadata: AlarmMetadata { var taskID: String }
    #endif
}
