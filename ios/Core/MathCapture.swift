import Foundation

/// Image transcription is user-reviewed evidence, never an inferred mastery score.
struct MathCapture: Codable, Sendable, Equatable {
    var statement: String
    var studentWork: String
    var referenceSolution: String
    var uncertainties: [String]

    func validated() throws -> Self {
        guard !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              statement.count <= 12_000, studentWork.count <= 8_000,
              referenceSolution.count <= 12_000, uncertainties.count <= 30,
              uncertainties.allSatisfy({ $0.count <= 500 }) else { throw MathStudyError.invalidInput }
        return self
    }

    static func decode(_ text: String) throws -> Self {
        var json = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```") {
            guard let first = json.firstIndex(of: "\n"), json.hasSuffix("```") else { throw MathStudyError.corruptData }
            json = String(json[json.index(after: first)..<json.index(json.endIndex, offsetBy: -3)])
        }
        guard let data = json.data(using: .utf8), data.count <= 180_000 else { throw MathStudyError.outputLimit }
        return try JSONDecoder().decode(Self.self, from: data).validated()
    }
}

struct MathCaptureRecord: Codable, Sendable, Equatable {
    let id: UUID
    let confirmedAt: Date
    let capture: MathCapture
    let images: [Data]
}

/// Sidecar file keeps the existing SwiftData schema (and ordinary chat store) unchanged.
struct MathCaptureArchive: Codable, Sendable {
    var schemaVersion = 1
    let problemID: UUID
    var records: [MathCaptureRecord]

    func validated(for id: UUID) throws -> Self {
        guard schemaVersion == 1, problemID == id, !records.isEmpty, records.count <= 20 else { throw MathStudyError.corruptData }
        for record in records {
            _ = try record.capture.validated()
            guard record.images.count <= 6, record.images.allSatisfy({ !$0.isEmpty && $0.count <= 1_200_000 }) else { throw MathStudyError.invalidPhoto }
        }
        return self
    }
}
