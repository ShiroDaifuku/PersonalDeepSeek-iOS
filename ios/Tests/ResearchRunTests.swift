import Foundation
import XCTest
@testable import PersonalDeepSeek

final class ResearchRunTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    private func budget(ceiling: Int = 3, wall: TimeInterval = 100) throws -> ResearchRun.Budget {
        try .init(rounds: ceiling, queries: ceiling, sources: ceiling, fetches: ceiling,
                  evidenceCharacters: ceiling, synthesisTokens: ceiling, wallSeconds: wall,
                  planningAttempts: ceiling, planningTokens: ceiling, searchRequests: ceiling)
    }

    private func makeRun(ceiling: Int = 3, wall: TimeInterval = 100) throws -> ResearchRun {
        try .init(conversationID: UUID(), query: "Research this question", budget: budget(ceiling: ceiling, wall: wall), now: start)
    }

    private func assertError(_ expected: ResearchRun.ValidationError, _ action: () throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try action(), file: file, line: line) { error in
            XCTAssertEqual(error as? ResearchRun.ValidationError, expected, file: file, line: line)
        }
    }

    func testLegalLifecycleAndRefinementTransitions() throws {
        var value = try makeRun()
        let identity = value.id
        let binding = value.conversationID
        for next in [ResearchRun.Phase.planning, .collecting, .evaluating, .collecting, .evaluating, .synthesizing, .completed] {
            try value.transition(to: next, at: start.addingTimeInterval(1))
            XCTAssertEqual(value.phase, next)
        }
        XCTAssertEqual(value.id, identity)
        XCTAssertEqual(value.conversationID, binding)
        XCTAssertEqual(value.query, "Research this question")
        XCTAssertNil(value.failure)
    }

    func testInvalidTransitionsAreAtomic() throws {
        var value = try makeRun()
        for next in [ResearchRun.Phase.queued, .collecting, .evaluating, .synthesizing, .completed, .cancelled, .failed] {
            let before = value
            assertError(.invalidTransition(.queued, next)) { try value.transition(to: next, at: start.addingTimeInterval(1)) }
            XCTAssertEqual(value, before)
        }
        try value.transition(to: .planning, at: start)
        assertError(.invalidTransition(.planning, .completed)) { try value.transition(to: .completed, at: start) }
    }

    private func fixture(in phase: ResearchRun.Phase) throws -> ResearchRun {
        var value = try makeRun()
        switch phase {
        case .queued: return value
        case .cancelled:
            try value.cancel(at: start)
            return value
        case .failed:
            try value.fail(.internalError, at: start)
            return value
        default:
            for next in [ResearchRun.Phase.planning, .collecting, .evaluating, .synthesizing, .completed] {
                try value.transition(to: next, at: start)
                if next == phase { return value }
            }
            throw ResearchRun.ValidationError.invalidCheckpoint
        }
    }

    func testExhaustiveTransitionMatrix() throws {
        let legalEdges: [ResearchRun.Phase: Set<ResearchRun.Phase>] = [
            .queued: [.planning], .planning: [.collecting], .collecting: [.evaluating],
            .evaluating: [.collecting, .synthesizing], .synthesizing: [.completed]
        ]
        for current in ResearchRun.Phase.allCases {
            for next in ResearchRun.Phase.allCases {
                var value = try fixture(in: current)
                let before = value
                if legalEdges[current]?.contains(next) == true {
                    try value.transition(to: next, at: start.addingTimeInterval(1))
                    XCTAssertEqual(value.phase, next)
                    XCTAssertEqual(value.usage, before.usage)
                } else {
                    let expected: ResearchRun.ValidationError = current.isTerminal
                        ? .terminalRun : .invalidTransition(current, next)
                    assertError(expected) { try value.transition(to: next, at: start.addingTimeInterval(1)) }
                    XCTAssertEqual(value, before)
                }
            }
        }
    }

    func testEveryTerminalOutcomeIsMonotonic() throws {
        for terminal in [ResearchRun.Phase.completed, .cancelled, .failed] {
            var value = try makeRun()
            switch terminal {
            case .completed:
                for next in [ResearchRun.Phase.planning, .collecting, .evaluating, .synthesizing, .completed] {
                    try value.transition(to: next, at: start)
                }
            case .cancelled: try value.cancel(at: start)
            case .failed: try value.fail(.providerUnavailable, at: start)
            default: XCTFail("Unexpected fixture")
            }
            let before = value
            for next in ResearchRun.Phase.allCases {
                assertError(.terminalRun) { try value.transition(to: next, at: start) }
            }
            assertError(.terminalRun) { try value.reserve([.queries: 1], at: start) }
            assertError(.terminalRun) { try value.cancel(at: start) }
            assertError(.terminalRun) { try value.fail(.internalError, at: start) }
            XCTAssertEqual(value, before)
        }
    }

    func testAllResourceCeilingsAndAtomicMultidimensionalReservation() throws {
        for resource in ResearchRun.Resource.allCases {
            var value = try makeRun()
            try value.reserve([resource: 3], at: start)
            XCTAssertEqual(value.usage[resource], 3)
            let before = value
            assertError(.budgetExceeded(resource)) {
                try value.reserve([resource: 1, (resource == .queries ? .sources : .queries): 1], at: start.addingTimeInterval(1))
            }
            XCTAssertEqual(value, before)
        }
    }

    func testInvalidReservationsAndOverflowAreAtomic() throws {
        var value = try makeRun(ceiling: Int.max)
        for costs in ([[:], [.queries: 0], [.queries: -1], [.rounds: 1, .fetches: -1]] as [[ResearchRun.Resource: Int]]) {
            let before = value
            assertError(.invalidReservation) { try value.reserve(costs, at: start) }
            XCTAssertEqual(value, before)
        }
        try value.reserve([.queries: Int.max], at: start)
        let before = value
        assertError(.budgetExceeded(.queries)) { try value.reserve([.queries: 1], at: start) }
        XCTAssertEqual(value, before)
    }

    func testRejectsEachInvalidBudgetDimensionAndQuery() throws {
        for resource in ResearchRun.Resource.allCases {
            for invalid in [0, -1] {
                var limits = Dictionary(uniqueKeysWithValues: ResearchRun.Resource.allCases.map { ($0, 1) })
                limits[resource] = invalid
                assertError(.invalidBudget) {
                    _ = try ResearchRun.Budget(rounds: limits[.rounds]!, queries: limits[.queries]!, sources: limits[.sources]!,
                        fetches: limits[.fetches]!, evidenceCharacters: limits[.evidenceCharacters]!,
                        synthesisTokens: limits[.synthesisTokens]!, wallSeconds: 100,
                        planningAttempts: limits[.planningAttempts]!, planningTokens: limits[.planningTokens]!, searchRequests: limits[.searchRequests]!)
                }
            }
        }
        for wall in [0.0, -1.0, Double.infinity, Double.nan] {
            assertError(.invalidBudget) { _ = try budget(wall: wall) }
        }
        assertError(.invalidQuery) {
            _ = try ResearchRun(conversationID: UUID(), query: " \n ", budget: budget(), now: start)
        }
        assertError(.invalidCheckpoint) {
            _ = try ResearchRun(conversationID: UUID(), query: "question", budget: budget(), now: Date(timeIntervalSinceReferenceDate: .infinity))
        }
    }

    func testWallDeadlineAndBackwardsClockLeaveStateUntouched() throws {
        var value = try makeRun(wall: 10)
        try value.reserve([.queries: 1], at: start.addingTimeInterval(5))
        let before = value
        assertError(.invalidClock) { try value.reserve([.queries: 1], at: start.addingTimeInterval(4)) }
        assertError(.invalidClock) { _ = try value.elapsed(at: Date(timeIntervalSinceReferenceDate: .nan)) }
        assertError(.wallTimeExceeded) { try value.transition(to: .planning, at: start.addingTimeInterval(10)) }
        assertError(.wallTimeExceeded) { try value.reserve([.fetches: 1], at: start.addingTimeInterval(11)) }
        XCTAssertEqual(value, before)
        XCTAssertEqual(try value.elapsed(at: start.addingTimeInterval(9)), 9)
        try value.fail(.budgetExhausted, at: start.addingTimeInterval(11))
        XCTAssertEqual(value.phase, .failed)
        XCTAssertEqual(value.failure, .budgetExhausted)
        var cancelled = try makeRun(wall: 10)
        try cancelled.cancel(at: start.addingTimeInterval(20))
        XCTAssertEqual(cancelled.phase, .cancelled)
        XCTAssertNil(cancelled.failure)
    }

    func testCheckpointRoundTripPreservesIdentityUsageAndOriginalDeadline() throws {
        var original = try makeRun(wall: 10)
        try original.transition(to: .planning, at: start.addingTimeInterval(1))
        try original.reserve([.queries: 2, .fetches: 1, .planningAttempts: 1, .planningTokens: 3, .searchRequests: 2], at: start.addingTimeInterval(2))
        var restored = try JSONDecoder().decode(ResearchRun.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored, original)
        assertError(.wallTimeExceeded) { try restored.reserve([.queries: 1], at: start.addingTimeInterval(10)) }
        XCTAssertEqual(restored, original)
        for terminal in [ResearchRun.Phase.cancelled, .failed] {
            var value = original
            if terminal == .cancelled { try value.cancel(at: start.addingTimeInterval(15)) }
            else { try value.fail(.invalidResponse, at: start.addingTimeInterval(15)) }
            XCTAssertEqual(try JSONDecoder().decode(ResearchRun.self, from: JSONEncoder().encode(value)), value)
        }
    }

    private func corrupted(_ value: ResearchRun, _ mutate: (inout [String: Any]) -> Void) throws -> Data {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        mutate(&json)
        return try JSONSerialization.data(withJSONObject: json)
    }

    func testCheckpointDecoderRejectsCorruptionAndFutureVersions() throws {
        let value = try makeRun()
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["version"] = 4 }, { $0["version"] = 1 }, { $0["version"] = 2 }, { $0["version"] = 0 }, { $0["query"] = " " },
            { $0["id"] = "invalid UUID" }, { $0.removeValue(forKey: "conversationID") },
            { $0["phase"] = "unknownPhase" }, { $0["phase"] = "failed" },
            { $0["failure"] = "internalError" },
            { $0["phase"] = "completed"; $0["failure"] = "internalError" },
            { $0["phase"] = "cancelled"; $0["failure"] = "internalError" },
            { $0["updatedAt"] = 999 }, { $0["updatedAt"] = 1_100 },
            { $0["usage"] = [] },
            { $0["usage"] = ["rounds", 0, "queries", 0, "sources", 0, "fetches", 0, "evidenceCharacters", 0] },
            { $0["usage"] = ["rounds", 0, "queries", 0, "sources", 0, "fetches", 0, "evidenceCharacters", 0, "synthesisTokens", 0, "planningAttempts", 0, "planningTokens", 0, "searchRequests", 0, "unexpected", 0] },
            { $0["usage"] = ["rounds", -1, "queries", 0, "sources", 0, "fetches", 0, "evidenceCharacters", 0, "synthesisTokens", 0, "planningAttempts", 0, "planningTokens", 0, "searchRequests", 0] },
            { $0["usage"] = ["rounds", 4, "queries", 0, "sources", 0, "fetches", 0, "evidenceCharacters", 0, "synthesisTokens", 0, "planningAttempts", 0, "planningTokens", 0, "searchRequests", 0] },
            { json in
                var config = json["budget"] as! [String: Any]
                config["wallSeconds"] = 0
                json["budget"] = config
            },
            { json in
                var config = json["budget"] as! [String: Any]
                config["limits"] = []
                json["budget"] = config
            },
            { json in
                var config = json["budget"] as! [String: Any]
                config["limits"] = ["rounds", 3, "queries", 3, "sources", 3, "fetches", 3, "evidenceCharacters", 3]
                json["budget"] = config
            },
            { json in
                var config = json["budget"] as! [String: Any]
                config["limits"] = ["rounds", 3, "queries", 3, "sources", 3, "fetches", 3, "evidenceCharacters", 3, "synthesisTokens", 3, "planningAttempts", 3, "planningTokens", 3, "searchRequests", 3, "unexpected", 3]
                json["budget"] = config
            }
        ]
        for mutate in mutations {
            let data = try corrupted(value, mutate)
            XCTAssertThrowsError(try JSONDecoder().decode(ResearchRun.self, from: data))
        }
        assertError(.unsupportedVersion(1)) {
            _ = try JSONDecoder().decode(ResearchRun.self, from: corrupted(value) { $0["version"] = 1 })
        }
        assertError(.unsupportedVersion(2)) {
            _ = try JSONDecoder().decode(ResearchRun.self, from: corrupted(value) { $0["version"] = 2 })
        }
        assertError(.unsupportedVersion(4)) {
            _ = try JSONDecoder().decode(ResearchRun.self, from: corrupted(value) { $0["version"] = 4 })
        }
        for resource in [ResearchRun.Resource.planningAttempts, .planningTokens, .searchRequests] {
            for field in ["usage", "limits"] {
                let data = try corrupted(value) { json in
                    var container = field == "usage" ? json : json["budget"] as! [String: Any]
                    var pairs = container[field] as! [Any]
                    let index = pairs.firstIndex { ($0 as? String) == resource.rawValue }!
                    pairs.removeSubrange(index...index + 1)
                    container[field] = pairs
                    if field == "usage" { json = container } else { json["budget"] = container }
                }
                XCTAssertThrowsError(try JSONDecoder().decode(ResearchRun.self, from: data))
            }
        }
    }

    func testV3EveryResourceCheckpointCorruptionIsIsolated() throws {
        let value = try makeRun()
        XCTAssertEqual(ResearchRun.checkpointVersion, 3)
        XCTAssertEqual(ResearchRun.Resource.allCases.count, 9)
        for resource in ResearchRun.Resource.allCases {
            for field in ["usage", "limits"] {
                for invalid in [nil, -1, 4] as [Int?] {
                    // A limit of 4 is valid, so only usage exercises the over-budget case.
                    if field == "limits", invalid == 4 { continue }
                    let data = try corrupted(value) { json in
                        var container = field == "usage" ? json : json["budget"] as! [String: Any]
                        var pairs = container[field] as! [Any]
                        let index = pairs.firstIndex { ($0 as? String) == resource.rawValue }!
                        if let invalid { pairs[index + 1] = invalid }
                        else { pairs.removeSubrange(index...index + 1) }
                        container[field] = pairs
                        if field == "usage" { json = container } else { json["budget"] = container }
                    }
                    assertError(field == "usage" ? .invalidCheckpoint : .invalidBudget) {
                        _ = try JSONDecoder().decode(ResearchRun.self, from: data)
                    }
                }
            }
        }
    }
}
