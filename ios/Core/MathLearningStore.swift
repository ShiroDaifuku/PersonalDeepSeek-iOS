import Foundation
import SwiftData

enum MathStudyError: LocalizedError, Sendable {
    case invalidInput, missingProblem, corruptData, emptyResponse, outputLimit, invalidPhoto
    var errorDescription: String? {
        switch self {
        case .invalidInput: "请确认题干，并检查输入长度或知识点分类。"
        case .missingProblem: "题目不存在，请重新打开题目列表。"
        case .corruptData: "数学档案包含无法读取的数据；不会删除或重建数据库。"
        case .emptyResponse: "未收到有效内容，请重试。"
        case .outputLimit: "本次输出达到上限，请缩小问题范围。"
        case .invalidPhoto: "照片无效或无法读取，请重新选择。"
        }
    }
}

enum MathStudyDatabase {
    static var schema: Schema { Schema([MathProblem.self, MathAttempt.self, MathKnowledgePoint.self, MathLearningEvidence.self]) }
    static func container(at url: URL) throws -> ModelContainer {
        try ModelContainer(for: schema, configurations: [ModelConfiguration("MathStudy", schema: schema, url: url, cloudKitDatabase: .none)])
    }
    static func localDirectory() throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = root.appendingPathComponent("MathStudy", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@ModelActor actor MathLearningStore {
    private func save() throws {
        do { try modelContext.save() } catch { modelContext.rollback(); throw error }
    }
    func seedTopics() throws {
        modelContext.autosaveEnabled = false
        let existing = Set(try modelContext.fetch(FetchDescriptor<MathKnowledgePoint>()).map(\.id))
        for topic in MathSyllabus.topics where !existing.contains(topic.id) { modelContext.insert(MathKnowledgePoint(topic: topic)) }
        try save()
    }
    func create(id: UUID, statement: String, subject: MathSubject, topicID: String?, photoFilename: String?) throws -> MathProblemSnapshot {
        modelContext.autosaveEnabled = false
        let text = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 12_000,
              topicID == nil || MathSyllabus.topics.contains(where: { $0.id == topicID && $0.subject == subject }),
              photoFilename == nil || photoFilename == "\(id.uuidString).jpg" else { throw MathStudyError.invalidInput }
        guard try problem(id) == nil else { throw MathStudyError.invalidInput }
        let value = MathProblem(id: id, statement: text, subject: subject, topicID: topicID, photoFilename: photoFilename)
        modelContext.insert(value); try save(); return try snapshot(value)
    }
    func list() throws -> [MathProblemSnapshot] {
        try modelContext.fetch(FetchDescriptor<MathProblem>(sortBy: [SortDescriptor(\MathProblem.createdAt, order: .reverse)])).map(snapshot)
    }
    func fetch(id: UUID) throws -> MathProblemSnapshot? { try problem(id).map(snapshot) }
    func append(problemID: UUID, attemptID: UUID, mode: MathTeachingMode, userWork: String, response: String, status: MathAttemptStatus) throws -> MathProblemSnapshot {
        modelContext.autosaveEnabled = false
        guard let value = try problem(problemID) else { throw MathStudyError.missingProblem }
        guard userWork.count <= 8_000, response.count <= 32_000 else { throw MathStudyError.invalidInput }
        // A retried save is idempotent, but a colliding different payload is never accepted.
        let all = try modelContext.fetch(FetchDescriptor<MathAttempt>(predicate: #Predicate { $0.id == attemptID }))
        if let old = all.first {
            guard old.problem?.id == problemID, old.modeRawValue == mode.rawValue, old.userWork == userWork,
                  old.response == response, old.statusRawValue == status.rawValue else { throw MathStudyError.invalidInput }
            return try snapshot(value)
        }
        let attempt = MathAttempt(id: attemptID, mode: mode, userWork: userWork, response: response, status: status, problem: value)
        modelContext.insert(attempt); try save(); return try snapshot(value)
    }
    func delete(id: UUID) throws {
        modelContext.autosaveEnabled = false
        guard let value = try problem(id) else { throw MathStudyError.missingProblem }
        modelContext.delete(value); try save()
    }
    private func problem(_ id: UUID) throws -> MathProblem? {
        try modelContext.fetch(FetchDescriptor<MathProblem>(predicate: #Predicate { $0.id == id })).first
    }
    private func snapshot(_ value: MathProblem) throws -> MathProblemSnapshot {
        guard value.scopeID == MathStudyScope.local, let subject = MathSubject(rawValue: value.subjectRawValue) else { throw MathStudyError.corruptData }
        let attempts = try value.attempts.sorted { $0.createdAt < $1.createdAt }.map { attempt -> MathAttemptSnapshot in
            guard let mode = MathTeachingMode(rawValue: attempt.modeRawValue), let status = MathAttemptStatus(rawValue: attempt.statusRawValue) else { throw MathStudyError.corruptData }
            return .init(id: attempt.id, mode: mode, userWork: attempt.userWork, response: attempt.response, status: status, createdAt: attempt.createdAt)
        }
        return .init(id: value.id, statement: value.statement, subject: subject, topicID: value.topicID, photoFilename: value.photoFilename, createdAt: value.createdAt, attempts: attempts)
    }
}
