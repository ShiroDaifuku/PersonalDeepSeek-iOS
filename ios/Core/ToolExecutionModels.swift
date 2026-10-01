import Foundation
import SwiftData

enum ToolExecutionStatus: String, Codable, Sendable, CaseIterable {
    case running
    case succeeded
    case failed
    case cancelled
}

enum ToolResultKind: String, Codable, Sendable {
    case webSearch = "web_search"
    case localKnowledge = "local_knowledge"
    case actionPrepared = "action_prepared"
}

enum ToolFetchStatus: String, Codable, Sendable {
    case fetched
    case snippetOnly = "snippet_only"
}

@Model final class ToolExecutionRecord {
    @Attribute(.unique) var id: UUID
    var conversationID: UUID
    var userMessageID: UUID?
    var assistantMessageID: UUID?
    var toolName: String
    var statusRawValue: String
    var query: String?
    var argumentsData: Data?
    var resultData: Data?
    var errorCode: String?
    var startedAt: Date
    var completedAt: Date?
    var schemaVersion: Int
    var toolCallID: String?
    var roundIndex: Int?
    var parentExecutionID: UUID?

    init(
        id: UUID = UUID(),
        conversationID: UUID,
        userMessageID: UUID? = nil,
        assistantMessageID: UUID? = nil,
        toolName: String,
        statusRawValue: String = ToolExecutionStatus.running.rawValue,
        query: String? = nil,
        argumentsData: Data? = nil,
        resultData: Data? = nil,
        errorCode: String? = nil,
        startedAt: Date = Date(),
        completedAt: Date? = nil,
        schemaVersion: Int = 1,
        toolCallID: String? = nil,
        roundIndex: Int? = nil,
        parentExecutionID: UUID? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.userMessageID = userMessageID
        self.assistantMessageID = assistantMessageID
        self.toolName = toolName
        self.statusRawValue = statusRawValue
        self.query = query
        self.argumentsData = argumentsData
        self.resultData = resultData
        self.errorCode = errorCode
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.schemaVersion = schemaVersion
        self.toolCallID = toolCallID
        self.roundIndex = roundIndex
        self.parentExecutionID = parentExecutionID
    }
}

struct ToolExecutionRecordSnapshot: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let conversationID: UUID
    let userMessageID: UUID?
    let assistantMessageID: UUID?
    let toolName: String
    let statusRawValue: String
    let query: String?
    let argumentsData: Data?
    let resultData: Data?
    let errorCode: String?
    let startedAt: Date
    let completedAt: Date?
    let schemaVersion: Int
    let toolCallID: String?
    let roundIndex: Int?
    let parentExecutionID: UUID?

    var status: ToolExecutionStatus? { ToolExecutionStatus(rawValue: statusRawValue) }
}

struct ToolExecutionDraft: Sendable, Equatable {
    var id = UUID()
    let conversationID: UUID
    let userMessageID: UUID?
    let assistantMessageID: UUID?
    let toolName: String
    let query: String?
    let argumentsData: Data?
    var startedAt = Date()
    var schemaVersion = 1
    var toolCallID: String?
    var roundIndex: Int?
    var parentExecutionID: UUID?
}

struct ToolArgumentsEnvelope: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1
    let schemaVersion: Int
    let query: String?
    let limit: Int?

    init(query: String?, limit: Int? = nil) {
        schemaVersion = Self.currentSchemaVersion
        self.query = query
        self.limit = limit
    }
}

struct PersistedWebSource: Codable, Sendable, Equatable {
    let title: String
    let url: String
    let snippet: String
    let relevantExcerpt: String?
    let fetchStatus: ToolFetchStatus
}

struct WebSearchToolPayload: Codable, Sendable, Equatable {
    let provider: String
    let sourceCount: Int
    let sources: [PersistedWebSource]
}

struct LocalKnowledgeToolPayload: Codable, Sendable, Equatable {
    let resultCount: Int
    let boundedContext: String
}

struct PreparedActionToolPayload: Codable, Sendable, Equatable {
    let action: String
    let confirmationRequired: Bool
    let saved: Bool
}

enum ToolResultPayload: Codable, Sendable, Equatable {
    case webSearch(WebSearchToolPayload)
    case localKnowledge(LocalKnowledgeToolPayload)
    case actionPrepared(PreparedActionToolPayload)

    private enum CodingKeys: String, CodingKey { case type, webSearch, localKnowledge, actionPrepared }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .webSearch(let payload):
            try values.encode(ToolResultKind.webSearch.rawValue, forKey: .type)
            try values.encode(payload, forKey: .webSearch)
        case .localKnowledge(let payload):
            try values.encode(ToolResultKind.localKnowledge.rawValue, forKey: .type)
            try values.encode(payload, forKey: .localKnowledge)
        case .actionPrepared(let payload):
            try values.encode(ToolResultKind.actionPrepared.rawValue, forKey: .type)
            try values.encode(payload, forKey: .actionPrepared)
        }
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .type) {
        case ToolResultKind.webSearch.rawValue:
            self = .webSearch(try values.decode(WebSearchToolPayload.self, forKey: .webSearch))
        case ToolResultKind.localKnowledge.rawValue:
            self = .localKnowledge(try values.decode(LocalKnowledgeToolPayload.self, forKey: .localKnowledge))
        case ToolResultKind.actionPrepared.rawValue:
            self = .actionPrepared(try values.decode(PreparedActionToolPayload.self, forKey: .actionPrepared))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: values, debugDescription: "Unknown tool result payload")
        }
    }
}

struct ToolResultEnvelope: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1
    let schemaVersion: Int
    let toolName: String
    let query: String?
    let executedAt: Date
    let resultKind: ToolResultKind
    let payload: ToolResultPayload

    init(toolName: String, query: String?, executedAt: Date, resultKind: ToolResultKind, payload: ToolResultPayload) {
        schemaVersion = Self.currentSchemaVersion
        self.toolName = toolName
        self.query = query
        self.executedAt = executedAt
        self.resultKind = resultKind
        self.payload = payload
    }
}

enum ToolExecutionError: LocalizedError, Sendable, Equatable {
    case invalidRecord
    case recordNotFound
    case invalidTransition
    case encodingFailure
    case decodingFailure
    case persistenceFailure(String)

    var errorDescription: String? {
        switch self {
        case .invalidRecord: "Tool execution record is invalid."
        case .recordNotFound: "Tool execution record was not found."
        case .invalidTransition: "Tool execution status transition is invalid."
        case .encodingFailure: "Tool execution payload could not be encoded."
        case .decodingFailure: "Tool execution payload could not be decoded."
        case .persistenceFailure(let detail): "Tool execution persistence failed: \(detail)"
        }
    }
}
