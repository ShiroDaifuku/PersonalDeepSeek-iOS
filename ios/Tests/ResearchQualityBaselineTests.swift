import Foundation
import XCTest
@testable import PersonalDeepSeek

final class ResearchQualityBaselineTests: XCTestCase {
    private struct Case: Decodable {
        let id: String
        let query: String
        let expectedCharacteristics: [String]
        let evaluationNotes: [String]
        let citationExpectation: String
        let expectedSourceDiversity: Int

        enum CodingKeys: String, CodingKey {
            case id, query
            case expectedCharacteristics = "expected_characteristics"
            case evaluationNotes = "evaluation_notes"
            case citationExpectation = "citation_expectation"
            case expectedSourceDiversity = "expected_source_diversity"
        }
    }

    func testBaselineFixtureIsDecodableAndComplete() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "deep-research-quality-baseline", withExtension: "json"
        ))
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
        XCTAssertTrue((12...20).contains(cases.count))
        XCTAssertEqual(Set(cases.map(\.id)).count, cases.count)
        for item in cases {
            XCTAssertFalse(item.id.isEmpty)
            XCTAssertFalse(item.query.isEmpty)
            XCTAssertFalse(item.expectedCharacteristics.isEmpty)
            XCTAssertFalse(item.evaluationNotes.isEmpty)
            XCTAssertFalse(item.citationExpectation.isEmpty)
            XCTAssertGreaterThan(item.expectedSourceDiversity, 0)
        }
    }
}
