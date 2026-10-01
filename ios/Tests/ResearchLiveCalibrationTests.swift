import Foundation
import XCTest
@testable import PersonalDeepSeek

final class ResearchLiveCalibrationTests: XCTestCase {
    func testOptInResearchSynthesisAndTokenCalibration() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PERSONALDEEPSEEK_RUN_LIVE_RESEARCH_EVALS"] == "1" else {
            throw XCTSkip("Set PERSONALDEEPSEEK_RUN_LIVE_RESEARCH_EVALS=1 to run live calibration.")
        }
        guard let key = environment["DEEPSEEK_API_KEY"], !key.isEmpty else {
            throw XCTSkip("DEEPSEEK_API_KEY is not available.")
        }
        let model = environment["PERSONALDEEPSEEK_RESEARCH_MODEL"] ?? DeepSeekModelCompatibility.flash
        let cases = calibrationCases()
        let client = APIClient(apiKeyProvider: { key })

        for (index, item) in cases.enumerated() {
            let assembled = try ChatRequestAssembler.researchMessages(
                system: "Answer concisely and follow the supplied research evidence.",
                history: item.history,
                researchQuestion: item.question,
                researchSources: item.sources,
                memoryContext: nil,
                runtimeClockContext: RuntimeClockContext.current(
                    now: Date(timeIntervalSince1970: 1_800_000_000),
                    timeZone: TimeZone(secondsFromGMT: 0)!
                ),
                newUserText: item.question,
                now: Date(timeIntervalSince1970: 1_800_000_000),
                timeZone: TimeZone(secondsFromGMT: 0)!
            )
            var usage: StreamUsage?
            var receivedContent = false
            for try await delta in client.stream(
                messages: assembled.messages,
                model: model,
                thinking: true,
                reasoningEffort: "low"
            ) {
                switch delta {
                case .content(let value): receivedContent = receivedContent || !value.isEmpty
                case .usage(let value): usage = value
                case .reasoning, .done: break
                }
            }
            let measured = try XCTUnwrap(usage)
            let promptTokens = try XCTUnwrap(measured.promptTokens)
            XCTAssertTrue(receivedContent)
            XCTAssertGreaterThan(promptTokens, 0)
            let ratio = Double(assembled.usage.totalRetainedTextCharacters) / Double(promptTokens)
            // Numeric-only output: case index, retained chars, prompt tokens,
            // chars/token, completion tokens, reasoning tokens.
            print("\(index),\(assembled.usage.totalRetainedTextCharacters),\(promptTokens),\(ratio),\(measured.completionTokens ?? -1),\(measured.reasoningTokens ?? -1)")
        }
    }

    private struct CalibrationCase {
        let question: String
        let history: [ChatMessage]
        let sources: [ResearchSource]
    }

    private func calibrationCases() -> [CalibrationCase] {
        let sixSources = (1...6).map { number in
            ResearchSource(
                title: "Source \(number)",
                url: URL(string: "https://example.com/\(number)?a=1&b=2")!,
                snippet: "A bounded source summary.",
                pageText: String(repeating: "Evidence \(number) supports a controlled fixture. ", count: 80)
            )
        }
        var longHistory: [ChatMessage] = []
        for index in 0..<40 {
            longHistory.append(message(role: "user", content: "Earlier question \(index) " + String(repeating: "context ", count: 30), offset: Double(index * 2)))
            longHistory.append(message(role: "assistant", content: "Earlier answer \(index) " + String(repeating: "detail ", count: 30), offset: Double(index * 2 + 1)))
        }
        let oneSource = [ResearchSource(
            title: "Controlled source", url: URL(string: "https://example.com/fact")!,
            snippet: "The fixture says the answer should stay concise.",
            pageText: "This is deterministic local evidence used only to test request assembly and API compatibility."
        )]
        return [
            .init(question: "请根据资料给出一句中文结论。", history: [], sources: oneSource),
            .init(question: "Give one concise English conclusion from the evidence.", history: [], sources: oneSource),
            .init(question: "请 provide a concise 中英 mixed conclusion.", history: [], sources: oneSource),
            .init(question: "Explain this code briefly: `let values = rows.map(\\.id)`.", history: [], sources: oneSource),
            .init(question: "Compare https://example.com/a?x=1 and https://example.com/b?y=2 using the evidence.", history: [], sources: oneSource),
            .init(question: "Use the recent context and give one conclusion.", history: longHistory, sources: oneSource),
            .init(question: "Synthesize the six controlled sources with citations.", history: [], sources: sixSources)
        ]
    }

    private func message(role: String, content: String, offset: TimeInterval) -> ChatMessage {
        let value = ChatMessage(role: role, content: content)
        value.createdAt = Date(timeIntervalSince1970: 1_800_000_000 + offset)
        return value
    }
}
