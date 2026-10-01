import Foundation
import XCTest
@testable import PersonalDeepSeek

final class ResearchContextCalibrationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let timeZone = TimeZone(secondsFromGMT: 0)!

    func testConfiguredTextBoundarySucceedsAndBoundaryPlusOneFails() throws {
        let baseline = try assemble(userText: "")
        let fillCount = baseline.usage.maximumInputCharacters - baseline.usage.totalRetainedTextCharacters
        XCTAssertGreaterThan(fillCount, 0)

        let exact = try assemble(userText: String(repeating: "x", count: fillCount))
        XCTAssertEqual(exact.usage.totalRetainedTextCharacters, exact.usage.maximumInputCharacters)
        XCTAssertEqual(exact.messages.last?.content.count, fillCount)

        XCTAssertThrowsError(try assemble(userText: String(repeating: "x", count: fillCount + 1)))
    }

    func testRetainedTextCanReach47999Characters() throws {
        let baseline = try assemble(userText: "")
        let fillCount = 47_999 - baseline.usage.totalRetainedTextCharacters
        let result = try assemble(userText: String(repeating: "界", count: fillCount))
        XCTAssertEqual(result.usage.totalRetainedTextCharacters, 47_999)
    }

    func testSwiftCharacterAccountingIsDeterministicForRepresentativeText() throws {
        let values = [
            String(repeating: "中文内容", count: 400),
            String(repeating: "👩🏽‍💻", count: 400),
            String(repeating: "e\u{301}", count: 400),
            String(repeating: "https://example.com/a?x=1&y=2 ", count: 200),
            String(repeating: #"{"key":[1,2,3]}"#, count: 200),
            String(repeating: "## Heading\n```swift\nlet n = 1\n```\n", count: 100)
        ]
        for value in values {
            let result = try assemble(userText: value)
            XCTAssertEqual(result.messages.last?.content, value)
            XCTAssertLessThanOrEqual(result.usage.totalRetainedTextCharacters, result.usage.maximumInputCharacters)
        }
    }

    func testInlineBase64IsProtectedMultimodalPayloadNotTextBudget() throws {
        let small = "data:image/jpeg;base64," + Data(repeating: 0xAB, count: 1_024).base64EncodedString()
        let phonePhoto = "data:image/jpeg;base64," + Data(repeating: 0xCD, count: 1_200_000).base64EncodedString()
        for image in [small, phonePhoto] {
            let result = try assemble(userText: "分析图片", imageDataURLs: [image])
            XCTAssertEqual(result.messages.last?.imageDataURLs, [image])
            XCTAssertEqual(result.usage.protectedMultimodalPayloadCharacters, image.count)
            XCTAssertLessThan(result.usage.totalRetainedTextCharacters, 48_000)
        }
    }

    func testImageWithLongHistoryAndEvidenceStillUsesTextBudgetOnly() throws {
        let image = "data:image/jpeg;base64," + Data(repeating: 0xEF, count: 1_200_000).base64EncodedString()
        var history: [ChatMessage] = []
        for index in 0..<120 {
            let userText = "old-user-\(index)-" + String(repeating: "中", count: 160)
            let answerText = "old-answer-\(index)-" + String(repeating: "a", count: 160)
            history.append(message(role: "user", content: userText, offset: Double(index * 2)))
            history.append(message(role: "assistant", content: answerText, offset: Double(index * 2 + 1)))
        }
        let result = try ChatRequestAssembler.researchMessages(
            system: "system",
            history: history,
            researchQuestion: "compare",
            researchSources: sources(count: 6, bodyCharacters: 9_000),
            memoryContext: nil,
            runtimeClockContext: RuntimeClockContext.current(now: now, timeZone: timeZone),
            newUserText: "CURRENT_IMAGE_REQUEST",
            imageDataURLs: [image],
            now: now,
            timeZone: timeZone
        )
        XCTAssertEqual(result.messages.last?.content, "CURRENT_IMAGE_REQUEST")
        XCTAssertEqual(result.messages.last?.imageDataURLs, [image])
        XCTAssertEqual(result.usage.protectedMultimodalPayloadCharacters, image.count)
        XCTAssertLessThanOrEqual(result.usage.totalRetainedTextCharacters, result.usage.maximumInputCharacters)
        XCTAssertLessThan(result.usage.historyRetainedMessageCount, history.count)
    }

    func testPriorToolHistoryIsBoundedAndCannotExposeCurrentCitationLabels() throws {
        let historical = """
        Prior tool activity.
        \(ToolHistoryContextBuilder.jsonMarker)
        {"excerpt":"[1] Historical source and [22] older source"}
        """
        let snapshot = ToolHistoryContextSnapshot(
            executions: [], messageContent: historical,
            characterCount: historical.count, estimatedTokens: 30
        )
        let safe = ToolHistoryContextBuilder.researchSafe(snapshot)
        XCTAssertLessThanOrEqual(safe.characterCount, ToolHistoryContextBudget.chatDefault.maximumCharacters)
        XCTAssertFalse(safe.messageContent.contains("[1] Historical"))
        XCTAssertFalse(safe.messageContent.contains("[22]"))
        XCTAssertTrue(safe.messageContent.contains("［1］ Historical"))
        XCTAssertTrue(safe.messageContent.contains("non-citeable"))

        let result = try ChatRequestAssembler.researchMessages(
            system: "system", history: [], researchQuestion: "q",
            researchSources: sources(count: 2, bodyCharacters: 20),
            toolHistoryContext: snapshot, memoryContext: nil,
            newUserText: "question", now: now, timeZone: timeZone
        )
        let prior = try XCTUnwrap(result.messages.first { $0.content.contains("UNTRUSTED_PRIOR_TOOL_RESULTS_JSON") })
        let current = try XCTUnwrap(result.messages.first { $0.content.contains("Web research evidence:") })
        XCTAssertFalse(prior.content.contains("[1] Historical"))
        XCTAssertTrue(current.content.contains("[1] Title 1"))
        XCTAssertTrue(current.content.contains("[2] Title 2"))
    }

    func testPathologicalMetadataCannotBypassEvidenceBudget() throws {
        let longURL = URL(string: "https://example.com/" + String(repeating: "segment/", count: 2_000))!
        let source = ResearchSource(
            title: String(repeating: "Long title ", count: 1_000),
            url: longURL,
            snippet: String(repeating: "snippet", count: 2_000),
            pageText: ""
        )
        let result = try ResearchContextBudgeter.prepare(
            question: "q", sources: [source], history: [],
            fixedCharacterCount: 200, mandatoryCharacterCount: 100,
            policy: policy(), now: now, timeZone: timeZone
        )
        XCTAssertLessThanOrEqual(result.evidencePrompt.count, 8_000)
        XCTAssertLessThanOrEqual(result.evidenceSources[0].title.count, 500)
        XCTAssertTrue(result.evidencePrompt.contains("…"))
    }

    func testHundredTurnHistoryDropsOldestAndNeverKeepsOrphanAssistant() throws {
        var history: [ChatMessage] = [message(role: "assistant", content: "ORPHAN", offset: -1)]
        for index in 0..<110 {
            history.append(message(role: "user", content: "U\(index)-" + String(repeating: "中", count: 100), offset: Double(index * 3)))
            history.append(message(role: "tool", content: "TOOL\(index)", offset: Double(index * 3 + 1)))
            history.append(message(role: "assistant", content: "A\(index)-" + String(repeating: "e", count: 100), offset: Double(index * 3 + 2)))
        }
        let result = try ChatRequestAssembler.researchMessages(
            system: "system", history: history, researchQuestion: "q",
            researchSources: sources(count: 2, bodyCharacters: 100), memoryContext: nil,
            newUserText: "CURRENT", policy: policy(), now: now, timeZone: timeZone
        )
        XCTAssertEqual(result.messages.last?.content, "CURRENT")
        XCTAssertFalse(result.messages.contains { $0.content == "ORPHAN" || $0.role == "tool" })
        let retained = result.messages.filter { $0.role == "user" || $0.role == "assistant" }
        XCTAssertTrue(retained.contains { $0.content.contains("U109-") })
        XCTAssertFalse(retained.contains { $0.content.contains("U0-") })
        XCTAssertNotEqual(retained.first?.role, "assistant")
    }

    func testRuntimeClockAndProductionModelCompatibilityAreBoundedAndDeterministic() {
        let clock = RuntimeClockContext(
            localDateTime: String(repeating: "L", count: 2_000),
            utcDateTime: String(repeating: "U", count: 2_000),
            timeZoneIdentifier: String(repeating: "T", count: 2_000)
        )
        XCTAssertLessThanOrEqual(clock.messageContent.count, RuntimeClockContext.maximumMessageCharacters)
        XCTAssertEqual(DeepSeekModelCompatibility.requestModel(for: "deepseek-chat"), "deepseek-flash")
        XCTAssertEqual(DeepSeekModelCompatibility.requestModel(for: "deepseek-reasoner"), "deepseek-flash")
        XCTAssertEqual(DeepSeekModelCompatibility.requestModel(for: "deepseek-v4-flash"), "deepseek-flash")
        XCTAssertEqual(DeepSeekModelCompatibility.requestModel(for: "deepseek-v4-pro"), "deepseek-v4-pro")
        XCTAssertTrue(DeepSeekModelCompatibility.supportsImages("deepseek-flash"))
        XCTAssertFalse(DeepSeekModelCompatibility.supportsImages("deepseek-v4-pro"))
        XCTAssertFalse(DeepSeekModelCompatibility.supportsImages("custom-unknown-model"))
    }

    func testAPIClientRejectsKnownTextOnlyModelAndTooManyImagesBeforeNetwork() async {
        let image = "data:image/jpeg;base64,YQ=="
        let proStream = APIClient(apiKeyProvider: { "unused" }).stream(
            messages: [APIMessage(role: "user", content: "look", imageDataURLs: [image])],
            model: "deepseek-v4-pro", thinking: false, reasoningEffort: "none"
        )
        do {
            for try await _ in proStream {}
            XCTFail("Expected image capability rejection")
        } catch ClientError.modelDoesNotSupportImages(let model) {
            XCTAssertEqual(model, "deepseek-v4-pro")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let countStream = APIClient(apiKeyProvider: { "unused" }).stream(
            messages: [APIMessage(role: "user", content: "look", imageDataURLs: Array(repeating: image, count: 7))],
            model: "deepseek-flash", thinking: false, reasoningEffort: "none"
        )
        do {
            for try await _ in countStream {}
            XCTFail("Expected image count rejection")
        } catch ClientError.tooManyImages(let count) {
            XCTAssertEqual(count, 7)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func assemble(userText: String, imageDataURLs: [String] = []) throws -> ResearchAssembledRequest {
        try ChatRequestAssembler.researchMessages(
            system: "system", history: [], researchQuestion: "q",
            researchSources: [ResearchSource(title: "Title", url: URL(string: "https://example.com")!, snippet: "")],
            memoryContext: nil, runtimeClockContext: nil,
            newUserText: userText, imageDataURLs: imageDataURLs,
            now: now, timeZone: timeZone
        )
    }

    private func policy() -> ResearchContextBudgetPolicy {
        .init(
            maximumContextCharacters: 12_000, reservedHeadroomCharacters: 2_000,
            maximumHistoryCharacters: 4_000, maximumEvidenceCharacters: 8_000,
            maximumPageTextCharactersPerSource: 2_000,
            maximumSnippetCharactersPerSource: 600,
            maximumTitleCharactersPerSource: 500,
            maximumURLCharactersPerSource: 2_048
        )
    }

    private func sources(count: Int, bodyCharacters: Int) -> [ResearchSource] {
        (1...count).map { index in
            ResearchSource(
                title: "Title \(index)",
                url: URL(string: "https://example.com/\(index)")!,
                snippet: "Snippet \(index)",
                pageText: String(repeating: "证据\(index)", count: bodyCharacters / 3)
            )
        }
    }

    private func message(role: String, content: String, offset: TimeInterval) -> ChatMessage {
        let value = ChatMessage(role: role, content: content)
        value.createdAt = now.addingTimeInterval(offset)
        return value
    }
}
