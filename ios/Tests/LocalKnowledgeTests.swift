import XCTest
@testable import PersonalDeepSeek

final class LocalKnowledgeTests: XCTestCase {
    func testChunkingOverlapsAndTerminates() {
        let chunks = LocalKnowledgeIndex.chunk(String(repeating: "a", count: 2_000), size: 800, overlap: 120)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { !$0.isEmpty && $0.count <= 800 })
    }

    func testDeterministicChineseRetrieval() {
        let knowledgeBase = LocalKnowledgeBase(name: "测试")
        let document = LocalKnowledgeDocument(name: "水果.txt", mediaType: "text/plain", byteCount: 24, knowledgeBase: knowledgeBase)
        let text = "苹果和香蕉都属于水果"
        let chunk = LocalKnowledgeChunk(index: 0, text: text, embedding: LocalKnowledgeIndex.encode(LocalKnowledgeIndex.embedding(for: text)), document: document)
        document.chunks = [chunk]; knowledgeBase.documents = [document]
        let first = LocalKnowledgeIndex.search("苹果", in: [knowledgeBase])
        let second = LocalKnowledgeIndex.search("苹果", in: [knowledgeBase])
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.first?.documentName, "水果.txt")
        XCTAssertTrue(LocalKnowledgeIndex.search("量子火箭", in: [knowledgeBase]).isEmpty)
    }

    func testTaskContextSnapshotDoesNotUploadWholeKnowledgeBase() {
        let draft = TaskDraft(title: "摘要", kind: "one_off", schedule: .init(type: "once", expression: "2030-01-01T00:00:00Z", timezone: "UTC"), prompt: "总结苹果", tools: ["none"], notify: true)
        let result = LocalKnowledgeResult(id: UUID(), knowledgeBaseID: UUID(), documentID: UUID(), documentName: "水果.txt", index: 0, text: "苹果是水果", score: 0.9)
        let value = LocalKnowledgeIndex.attachingContext(to: draft, results: [result])
        XCTAssertTrue(value.prompt.contains("苹果是水果"))
        XCTAssertEqual(value.title, draft.title)
        XCTAssertEqual(value.schedule, draft.schedule)
    }
}
