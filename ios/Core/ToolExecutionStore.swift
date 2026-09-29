import Foundation
import SwiftData

@ModelActor
actor ToolExecutionStore {
    func begin(_ draft: ToolExecutionDraft) throws -> ToolExecutionRecordSnapshot {
        let name = draft.toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ToolExecutionError.invalidRecord }
        let record = ToolExecutionRecord(
            id: draft.id,
            conversationID: draft.conversationID,
            userMessageID: draft.userMessageID,
            assistantMessageID: draft.assistantMessageID,
            toolName: name,
            query: draft.query,
            argumentsData: draft.argumentsData,
            startedAt: draft.startedAt,
            schemaVersion: draft.schemaVersion,
            toolCallID: draft.toolCallID,
            roundIndex: draft.roundIndex,
            parentExecutionID: draft.parentExecutionID
        )
        modelContext.insert(record)
        try save()
        return snapshot(record)
    }

    func finish(
        id: UUID,
        status: ToolExecutionStatus,
        resultData: Data? = nil,
        errorCode: String? = nil,
        completedAt: Date = Date()
    ) throws -> ToolExecutionRecordSnapshot {
        guard status != .running else { throw ToolExecutionError.invalidTransition }
        guard let record = try record(id: id) else { throw ToolExecutionError.recordNotFound }
        guard record.statusRawValue == ToolExecutionStatus.running.rawValue else {
            throw ToolExecutionError.invalidTransition
        }
        record.statusRawValue = status.rawValue
        record.resultData = status == .succeeded ? resultData : nil
        record.errorCode = status == .succeeded ? nil : errorCode
        record.completedAt = completedAt
        try save()
        return snapshot(record)
    }

    func execution(id: UUID) throws -> ToolExecutionRecordSnapshot? {
        try record(id: id).map(snapshot)
    }

    func recentSuccessful(
        conversationID: UUID,
        excludingIDs: [UUID] = [],
        limit: Int
    ) throws -> [ToolExecutionRecordSnapshot] {
        guard limit > 0 else { return [] }
        let requestedConversationID = conversationID
        let succeeded = ToolExecutionStatus.succeeded.rawValue
        var descriptor = FetchDescriptor<ToolExecutionRecord>(
            predicate: #Predicate {
                $0.conversationID == requestedConversationID && $0.statusRawValue == succeeded
            },
            sortBy: [SortDescriptor(\ToolExecutionRecord.completedAt, order: .reverse)]
        )
        descriptor.fetchLimit = min(max(limit + excludingIDs.count, limit), 32)
        let excluded = Set(excludingIDs)
        return try fetch(descriptor).lazy.filter { !excluded.contains($0.id) }.prefix(limit).map(snapshot)
    }

    func records(conversationID: UUID, limit: Int = 100) throws -> [ToolExecutionRecordSnapshot] {
        guard limit > 0 else { return [] }
        let requestedConversationID = conversationID
        var descriptor = FetchDescriptor<ToolExecutionRecord>(
            predicate: #Predicate { $0.conversationID == requestedConversationID },
            sortBy: [SortDescriptor(\ToolExecutionRecord.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(0, min(limit, 1_000))
        return try fetch(descriptor).map(snapshot)
    }

    @discardableResult
    func deleteRecords(conversationID: UUID) throws -> Int {
        let requestedConversationID = conversationID
        let descriptor = FetchDescriptor<ToolExecutionRecord>(
            predicate: #Predicate { $0.conversationID == requestedConversationID }
        )
        let records = try fetch(descriptor)
        for record in records { modelContext.delete(record) }
        try save()
        return records.count
    }

    private func record(id: UUID) throws -> ToolExecutionRecord? {
        let requestedID = id
        var descriptor = FetchDescriptor<ToolExecutionRecord>(predicate: #Predicate { $0.id == requestedID })
        descriptor.fetchLimit = 1
        return try fetch(descriptor).first
    }

    private func snapshot(_ record: ToolExecutionRecord) -> ToolExecutionRecordSnapshot {
        .init(
            id: record.id,
            conversationID: record.conversationID,
            userMessageID: record.userMessageID,
            assistantMessageID: record.assistantMessageID,
            toolName: record.toolName,
            statusRawValue: record.statusRawValue,
            query: record.query,
            argumentsData: record.argumentsData,
            resultData: record.resultData,
            errorCode: record.errorCode,
            startedAt: record.startedAt,
            completedAt: record.completedAt,
            schemaVersion: record.schemaVersion,
            toolCallID: record.toolCallID,
            roundIndex: record.roundIndex,
            parentExecutionID: record.parentExecutionID
        )
    }

    private func fetch<T: PersistentModel>(_ descriptor: FetchDescriptor<T>) throws -> [T] {
        do { return try modelContext.fetch(descriptor) }
        catch { throw ToolExecutionError.persistenceFailure(error.localizedDescription) }
    }

    private func save() throws {
        do { try modelContext.save() }
        catch { modelContext.rollback(); throw ToolExecutionError.persistenceFailure(error.localizedDescription) }
    }
}

final class ToolExecutionService: Sendable {
    let store: ToolExecutionStore

    init(modelContainer: ModelContainer) {
        store = ToolExecutionStore(modelContainer: modelContainer)
    }

    func begin(
        conversationID: UUID,
        userMessageID: UUID?,
        assistantMessageID: UUID?,
        toolName: String,
        query: String?
    ) async throws -> ToolExecutionRecordSnapshot {
        let boundedQuery = query.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_000)) }
        let arguments: Data?
        do { arguments = try JSONEncoder.toolPersistence.encode(ToolArgumentsEnvelope(query: boundedQuery)) }
        catch { throw ToolExecutionError.encodingFailure }
        return try await store.begin(.init(
            conversationID: conversationID,
            userMessageID: userMessageID,
            assistantMessageID: assistantMessageID,
            toolName: toolName,
            query: boundedQuery,
            argumentsData: arguments
        ))
    }

    func succeed(id: UUID, envelope: ToolResultEnvelope) async throws -> ToolExecutionRecordSnapshot {
        let data: Data
        do { data = try JSONEncoder.toolPersistence.encode(envelope) }
        catch { throw ToolExecutionError.encodingFailure }
        return try await store.finish(id: id, status: .succeeded, resultData: data, completedAt: envelope.executedAt)
    }

    func fail(id: UUID, errorCode: String) async {
        _ = try? await store.finish(id: id, status: .failed, errorCode: Self.safeErrorCode(errorCode))
    }

    func cancel(id: UUID) async {
        _ = try? await store.finish(id: id, status: .cancelled, errorCode: "cancelled")
    }

    func contextForChat(
        conversationID: UUID,
        excludingIDs: [UUID] = [],
        budget: ToolHistoryContextBudget = .chatDefault
    ) async -> ToolHistoryContextSnapshot? {
        do {
            let records = try await store.recentSuccessful(
                conversationID: conversationID,
                excludingIDs: excludingIDs,
                limit: budget.maximumExecutions
            )
            return ToolHistoryContextBuilder.build(records: records, budget: budget)
        } catch {
            return nil
        }
    }

    private static func safeErrorCode(_ value: String) -> String {
        let cleaned = value.lowercased().map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" }
        return String(cleaned.prefix(80))
    }
}

extension JSONEncoder {
    static var toolPersistence: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var toolPersistence: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

@MainActor enum ToolExecutionCleanup {
    static func deleteRecords(conversationID: UUID, in context: ModelContext) throws {
        let requestedConversationID = conversationID
        let descriptor = FetchDescriptor<ToolExecutionRecord>(
            predicate: #Predicate { $0.conversationID == requestedConversationID }
        )
        try context.fetch(descriptor).forEach(context.delete)
    }
}
