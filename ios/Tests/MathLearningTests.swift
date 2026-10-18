import XCTest
import SwiftData
import SwiftUI
@testable import PersonalDeepSeek

private final class MathTestModel: AgentModelStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [AgentModelRequest] = []
    let text: String
    let delay: UInt64
    let reason: String
    init(text: String = "先检查定义域。", delay: UInt64 = 0, reason: String = "stop") {
        self.text = text; self.delay = delay; self.reason = reason
    }
    func requests() -> [AgentModelRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    func streamRound(_ request: AgentModelRequest) -> AsyncThrowingStream<StreamDelta, Error> {
        lock.lock(); captured.append(request); lock.unlock()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                    try Task.checkCancellation()
                    continuation.yield(.content(text)); continuation.yield(.finishReason(reason)); continuation.yield(.done); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@MainActor final class MathLearningTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("math-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func store() throws -> MathLearningStore {
        let schema = MathStudyDatabase.schema
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        return MathLearningStore(modelContainer: container)
    }
    private func example(attempts: [MathAttemptSnapshot] = []) -> MathProblemSnapshot {
        .init(id: UUID(), statement: "求 $f(x)=\\ln(x-1)$ 的定义域", subject: .calculus,
            topicID: "calc.limits", photoFilename: nil, createdAt: Date(), attempts: attempts)
    }
    private func wait(_ model: MathTutorViewModel) async throws {
        for _ in 0..<200 {
            if !model.busy { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Math task did not finish"); model.stop()
    }
    func testSyllabusHasStableUniqueIDsAndThreeSubjects() {
        XCTAssertEqual(Set(MathSyllabus.topics.map(\.id)).count, MathSyllabus.topics.count)
        XCTAssertEqual(Set(MathSyllabus.topics.map(\.subject)), Set(MathSubject.allCases))
        XCTAssertTrue(MathSyllabus.topics.contains { $0.id == "calc.curve-surface" })
        XCTAssertTrue(MathSyllabus.topics.contains { $0.id == "prob.testing" })
    }
    func testStorageCRUDIdempotenceCascadeAndSeed() async throws {
        let store = try store()
        try await store.seedTopics(); try await store.seedTopics()
        let id = UUID(), attemptID = UUID()
        let created = try await store.create(id: id, statement: "求极限", subject: .calculus, topicID: "calc.limits", photoFilename: nil)
        XCTAssertTrue(created.attempts.isEmpty)
        _ = try await store.append(problemID: id, attemptID: attemptID, mode: .hint, userWork: "不会展开", response: "试试等价无穷小", status: .completed)
        _ = try await store.append(problemID: id, attemptID: attemptID, mode: .hint, userWork: "不会展开", response: "试试等价无穷小", status: .completed)
        let loaded = try await store.fetch(id: id)
        XCTAssertEqual(loaded?.attempts.count, 1)
        do {
            _ = try await store.append(problemID: id, attemptID: attemptID, mode: .solution, userWork: "", response: "different", status: .completed)
            XCTFail("Colliding ID overwrote original")
        } catch { }
        try await store.delete(id: id)
        let remaining = try await store.list()
        XCTAssertTrue(remaining.isEmpty)
    }
    func testInvalidTopicEmptyStatementAndPathRejected() async throws {
        let store = try store()
        for (statement, topic, name) in [("", "calc.limits", ""), ("题目", "linear.eigen", ""), ("题目", "calc.limits", "../photo.jpg")] {
            do {
                _ = try await store.create(id: UUID(), statement: statement, subject: .calculus,
                    topicID: topic, photoFilename: name.isEmpty ? nil : name)
                XCTFail("Invalid input accepted")
            } catch { }
        }
        let values = try await store.list(); XCTAssertTrue(values.isEmpty)
    }
    func testPersistentReloadAndRealCascade() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("math.store"), id = UUID()
        try await writePersistent(url, id: id)
        let container = try MathStudyDatabase.container(at: url)
        let store = MathLearningStore(modelContainer: container)
        let loaded = try await store.fetch(id: id)
        XCTAssertEqual(loaded?.attempts.count, 1)
        XCTAssertEqual(loaded?.statement, "求极限")
        let before = ModelContext(container)
        XCTAssertEqual(try before.fetchCount(FetchDescriptor<MathLearningEvidence>()), 1)
        try await store.delete(id: id)
        let context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MathAttempt>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MathLearningEvidence>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<MathKnowledgePoint>()), MathSyllabus.topics.count)
    }
    private func writePersistent(_ url: URL, id: UUID) async throws {
        let container = try MathStudyDatabase.container(at: url)
        let store = MathLearningStore(modelContainer: container)
        try await store.seedTopics()
        _ = try await store.create(id: id, statement: "求极限", subject: .calculus, topicID: nil, photoFilename: nil)
        _ = try await store.append(problemID: id, attemptID: UUID(), mode: .nextStep, userWork: "先展开？", response: "先判断型别", status: .completed)
        // Fixture-only evidence insertion tests the future delete rule; production does not extract evidence.
        let context = ModelContext(container)
        let problem = try XCTUnwrap(context.fetch(FetchDescriptor<MathProblem>()).first)
        let attempt = try XCTUnwrap(problem.attempts.first)
        context.insert(MathLearningEvidence(topicID: "calc.limits", sourceAttemptID: attempt.id, note: "test-only fixture", problem: problem))
        try context.save()
    }
    func testPhotoPersistenceAndDeletion() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let service = MathLearningService(store: try store(), directory: root)
        let data = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 50)).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 100, height: 50))
        }
        let value = try await service.create(statement: "已确认题目", subject: .linearAlgebra, topicID: nil, photo: data)
        let photo = try await service.photo(for: value); XCTAssertEqual(photo, data)
        try await service.delete(value)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(value.photoFilename!).path))
        do { _ = try await service.create(statement: "题", subject: .calculus, topicID: nil, photo: Data("not-image".utf8)); XCTFail() } catch { }
    }
    func testNoOrdinaryDatabaseOrMemoryMutation() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let chatURL = root.appendingPathComponent("chat.store")
        let chatSchema = Schema([Conversation.self, ChatMessage.self])
        let chatContainer = try ModelContainer(for: chatSchema, configurations: [ModelConfiguration(schema: chatSchema, url: chatURL)])
        let chat = ModelContext(chatContainer)
        let a = Conversation(title: "A", systemPrompt: "private-A"), b = Conversation(title: "B", systemPrompt: "private-B")
        chat.insert(a); chat.insert(b)
        chat.insert(ChatMessage(role: "user", content: "original question", conversation: a))
        chat.insert(ChatMessage(role: "assistant", content: "original answer", conversation: a))
        chat.insert(ChatMessage(role: "user", content: "other question", conversation: b)); try chat.save()
        let mathContainer = try MathStudyDatabase.container(at: root.appendingPathComponent("math.store"))
        let math = MathLearningStore(modelContainer: mathContainer)
        _ = try await math.create(id: UUID(), statement: "求导", subject: .calculus, topicID: nil, photoFilename: nil)
        let reopened = try ModelContainer(for: chatSchema, configurations: [ModelConfiguration(schema: chatSchema, url: chatURL)])
        let reloaded = ModelContext(reopened)
        let conversations = try reloaded.fetch(FetchDescriptor<Conversation>())
        XCTAssertEqual(conversations.count, 2)
        XCTAssertEqual(try reloaded.fetchCount(FetchDescriptor<ChatMessage>()), 3)
        XCTAssertEqual(conversations.first { $0.title == "A" }?.systemPrompt, "private-A")
        XCTAssertEqual(conversations.first { $0.title == "A" }?.messages.count, 2)
        XCTAssertEqual(Set(try reloaded.fetch(FetchDescriptor<ChatMessage>()).map(\.content)), ["original question", "original answer", "other question"])
    }
    func testConcurrentStorageOperationsDoNotShareModels() async throws {
        let store = try store()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<30 {
                group.addTask {
                    if index.isMultiple(of: 3) { _ = try await store.list() }
                    else { _ = try await store.create(id: UUID(), statement: "题目 \(index)", subject: .calculus, topicID: nil, photoFilename: nil) }
                }
            }
            try await group.waitForAll()
        }
        let values = try await store.list(); XCTAssertEqual(values.count, 20)
    }
    func testTeachingModesAndRecognitionPrompts() throws {
        for mode in MathTeachingMode.allCases {
            let prompt = try MathTutorPrompt.teaching(problem: example(), mode: mode, work: "先令 x-1>0")
            XCTAssertEqual(prompt.first?.role, "system")
            XCTAssertTrue(prompt.first!.content.contains("考研数学一"))
            XCTAssertTrue(prompt.last!.content.contains(mode.title))
            XCTAssertTrue(prompt.allSatisfy { $0.imageDataURLs.isEmpty && $0.toolCalls == nil })
        }
        let hint = try MathTutorPrompt.teaching(problem: example(), mode: .hint, work: "")
        XCTAssertTrue(hint[0].content.contains("禁止给出最终答案"))
        XCTAssertThrowsError(try MathTutorPrompt.teaching(problem: example(), mode: .checkWork, work: "  "))
        let recognition = try MathTutorPrompt.recognition(target: "第2题", image: "data:image/jpeg;base64,test")
        XCTAssertTrue(recognition[0].content.contains("【不清晰】"))
        XCTAssertTrue(recognition[0].content.contains("不求解"))
        XCTAssertEqual(recognition.last?.imageDataURLs.count, 1)
        XCTAssertThrowsError(try MathTutorPrompt.recognition(target: "", image: "x"))
    }
    func testBoundedProblemOnlyHistoryExcludesFailedTurns() throws {
        let history = (0..<20).map { index in
            MathAttemptSnapshot(id: UUID(), mode: .hint, userWork: "work-\(index)", response: "response-\(index)",
                status: index == 19 ? .failed : .completed, createdAt: Date())
        }
        let messages = try MathTutorPrompt.teaching(problem: example(attempts: history), mode: .nextStep, work: "继续")
        XCTAssertEqual(messages.count, 15)
        XCTAssertFalse(messages.contains { $0.content.contains("response-19") || $0.content.contains("response-0") })
    }
    func testViewModelRequiresConfirmationAndHasNoAutomaticCalls() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = MathTestModel()
        let service = MathLearningService(store: try store(), directory: root)
        let model = MathTutorViewModel(service: service, client: .init(model: fake))
        model.statement = "求定义域"; await model.confirm()
        XCTAssertNil(model.current); XCTAssertTrue(fake.requests().isEmpty)
        model.reviewed = true; await model.confirm()
        XCTAssertNotNil(model.current); XCTAssertTrue(fake.requests().isEmpty)
        model.teach(); try await wait(model)
        XCTAssertEqual(model.current?.attempts.count, 1)
        XCTAssertEqual(model.current?.attempts.first?.status, .completed)
        let requests = fake.requests(); XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].toolNames.isEmpty); XCTAssertFalse(requests[0].thinking)
        XCTAssertEqual(requests[0].model, "deepseek-flash")
        XCTAssertEqual(requests[0].maxOutputTokens, 4096)
    }
    func testCancellationEmptyAndTruncatedOutputsAreNotCompleted() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        for fake in [MathTestModel(text: "", delay: 0), MathTestModel(text: "partial", reason: "length"), MathTestModel(delay: 2_000_000_000)] {
            let service = MathLearningService(store: try store(), directory: root)
            let model = MathTutorViewModel(service: service, client: .init(model: fake))
            model.statement = "题目"; model.reviewed = true; await model.confirm()
            model.teach()
            if fake.delay > 0 { try await Task.sleep(nanoseconds: 20_000_000); model.stop() }
            try await wait(model)
            XCTAssertFalse(model.busy)
            XCTAssertNotNil(model.error)
            XCTAssertNotEqual(model.current?.attempts.first?.status, .completed)
        }
    }
    func testRecognitionNeedsUserReviewAndDoesNotStoreProblem() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = MathTestModel(text: "求 $x^2$ 的导数。")
        let service = MathLearningService(store: try store(), directory: root)
        let model = MathTutorViewModel(service: service, client: .init(model: fake))
        model.photo = PendingAttachment(name: "test.jpg", mimeType: "image/jpeg", data: Data([1]))
        model.recognize(); try await wait(model)
        XCTAssertEqual(model.statement, "求 $x^2$ 的导数。")
        XCTAssertFalse(model.reviewed); XCTAssertNil(model.current)
        let records = try await service.list(); XCTAssertTrue(records.isEmpty)
        XCTAssertEqual(fake.requests().count, 1)
    }
    func testMathScreenCanMountWithDynamicTypeAndDarkMode() async throws {
        let service = MathLearningService(store: try store(), directory: try directory())
        let model = MathTutorViewModel(service: service, client: .init(model: MathTestModel()))
        let host = UIHostingController(rootView: NavigationStack { MathTutorView(model: model) }.environment(\.colorScheme, .dark).environment(\.dynamicTypeSize, .accessibility2))
        host.loadViewIfNeeded(); host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844); host.view.layoutIfNeeded()
        XCTAssertNotNil(host.view)
    }
}
