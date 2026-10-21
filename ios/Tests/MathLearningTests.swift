import XCTest
import SwiftData
import SwiftUI
import UIKit
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
        let chatSchema = Schema([Conversation.self, ChatMessage.self, LocalKnowledgeBase.self, LocalKnowledgeDocument.self,
            LocalKnowledgeChunk.self, UserMemoryProfile.self, MemoryItem.self, MemorySource.self, MemoryTurnRecord.self, ToolExecutionRecord.self])
        let chatContainer = try ModelContainer(for: chatSchema, configurations: [ModelConfiguration(schema: chatSchema, url: chatURL)])
        let chat = ModelContext(chatContainer)
        let a = Conversation(title: "A", systemPrompt: "private-A"), b = Conversation(title: "B", systemPrompt: "private-B")
        chat.insert(a); chat.insert(b)
        chat.insert(ChatMessage(role: "user", content: "original question", conversation: a))
        chat.insert(ChatMessage(role: "assistant", content: "original answer", conversation: a))
        chat.insert(ChatMessage(role: "user", content: "other question", conversation: b)); try chat.save()
        // Test fixture only: math production code never receives this MemoryStore.
        let originalMemory = MemoryStore(modelContainer: chatContainer)
        _ = try await originalMemory.getOrCreateProfile(scopeID: MemoryScope.localDefault)
        let profile = try await originalMemory.updateProfile(scopeID: MemoryScope.localDefault, expectedRevision: 0,
            payload: .init(sourceDigest: "existing-profile-fixture"))
        let memory = try await originalMemory.insertMemory(scopeID: MemoryScope.localDefault,
            draft: .init(kind: .preference, canonicalText: "existing unrelated preference"))
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
        let reopenedMemory = MemoryStore(modelContainer: reopened)
        let afterProfile = try await reopenedMemory.profile(scopeID: MemoryScope.localDefault)
        let afterMemory = try await reopenedMemory.memory(id: memory.id, scopeID: MemoryScope.localDefault)
        XCTAssertEqual(afterProfile, profile)
        XCTAssertEqual(afterMemory, memory)
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
        let fake = MathTestModel(text: #"{"statement":"求 $x^2$ 的导数。","studentWork":"先写幂函数求导","referenceSolution":"","uncertainties":[]}"#)
        let service = MathLearningService(store: try store(), directory: root)
        let model = MathTutorViewModel(service: service, client: .init(model: fake))
        model.photo = PendingAttachment(name: "test.jpg", mimeType: "image/jpeg", data: Data([1]))
        model.recognize(); try await wait(model)
        XCTAssertEqual(model.statement, "求 $x^2$ 的导数。")
        XCTAssertEqual(model.work, "先写幂函数求导")
        XCTAssertNotNil(model.pendingCapture)
        XCTAssertFalse(model.reviewed); XCTAssertNil(model.current)
        let records = try await service.list(); XCTAssertTrue(records.isEmpty)
        XCTAssertEqual(fake.requests().count, 1)
    }
    func testCaptureDecoderSeparatesWorkAndReferenceAndRejectsPartialJSON() throws {
        let value = try MathCapture.decode(#"{"statement":"求 $x^2$ 的导数","studentWork":"我写成 $x$","referenceSolution":"参考：$2x$","uncertainties":["末行不清楚"]}"#)
        XCTAssertEqual(value.studentWork, "我写成 $x$")
        XCTAssertEqual(value.referenceSolution, "参考：$2x$")
        XCTAssertEqual(try MathCapture.decode("```json\n" + String(data: JSONEncoder().encode(value), encoding: .utf8)! + "\n```"), value)
        for text in ["plain OCR", "{\"statement\":\"partial\"}", #"{"statement":"","studentWork":"","referenceSolution":"","uncertainties":[]}"#] {
            XCTAssertThrowsError(try MathCapture.decode(text))
        }
        XCTAssertThrowsError(try MathCapture(statement: "题", studentWork: String(repeating: "x", count: 8_001), referenceSolution: "", uncertainties: []).validated())
    }
    func testCaptureArchiveReloadMultipleProvenanceAndDelete() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let storage = try store()
        let service = MathLearningService(store: storage, directory: root)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80)).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        }
        let capture = MathCapture(statement: "求导", studentWork: "手写步骤", referenceSolution: "印刷参考", uncertainties: [])
        let problem = try await service.create(statement: capture.statement, subject: .calculus, topicID: nil, photo: image, capture: capture, images: [image, image])
        let reopened = MathLearningService(store: storage, directory: root)
        let first = try await reopened.captures(for: problem)
        XCTAssertEqual(first?.records.count, 1)
        XCTAssertEqual(first?.records.first?.images, [image, image])
        XCTAssertEqual(first?.records.first?.capture, capture)
        try await reopened.appendCapture(capture, images: [image], for: problem)
        let second = try await service.captures(for: problem)
        XCTAssertEqual(second?.records.count, 2)
        XCTAssertNotEqual(second?.records.first?.id, second?.records.last?.id)
        XCTAssertTrue(problem.attempts.isEmpty) // OCR is not a completed teaching turn or mastery evidence.
        try await service.delete(problem)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("\(problem.id).capture.json").path))
    }
    func testRecognitionConfirmationAndSupplementNeverTeachAutomatically() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let fake = MathTestModel(text: #"{"statement":"求导","studentWork":"手写做法","referenceSolution":"参考做法","uncertainties":[]}"#)
        let service = MathLearningService(store: try store(), directory: root)
        let model = MathTutorViewModel(service: service, client: .init(model: fake))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80)).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        }
        model.acceptPhoto(image); model.recognize(); try await wait(model)
        model.teach()
        XCTAssertEqual(fake.requests().count, 1)
        XCTAssertNil(model.current)
        await model.confirmCapture()
        XCTAssertNotNil(model.current)
        XCTAssertNil(model.pendingCapture)
        XCTAssertEqual(fake.requests().count, 1) // User's single UI confirmation starts teaching, storage does not.
        let saved = try XCTUnwrap(model.current)
        model.acceptPhoto(image); model.recognize(); try await wait(model)
        model.teach()
        XCTAssertEqual(fake.requests().count, 2) // Pending supplemental work cannot leak into teaching.
        await model.confirmCapture()
        let archive = try await service.captures(for: saved)
        XCTAssertEqual(archive?.records.count, 2)
        XCTAssertEqual(archive?.records.last?.capture.studentWork, "手写做法")
        let messages = try MathTutorPrompt.teaching(problem: saved, mode: .checkWork, work: model.work, capture: model.capture)
        XCTAssertTrue(messages.last!.content.contains("手写做法"))
        XCTAssertTrue(messages.contains { $0.content.contains("参考答案不是用户作答") })
        model.select(saved)
        for _ in 0..<200 { if !model.importing { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.work, "手写做法")
    }
    func testMalformedOrCancelledRecognitionDoesNotCreateOrReplaceArchive() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        for fake in [MathTestModel(text: "broken JSON"), MathTestModel(text: "{}", reason: "length"), MathTestModel(delay: 2_000_000_000)] {
            let service = MathLearningService(store: try store(), directory: root)
            let model = MathTutorViewModel(service: service, client: .init(model: fake))
            model.photo = PendingAttachment(name: "fixture.jpg", mimeType: "image/jpeg", data: Data([1]))
            model.recognize()
            if fake.delay > 0 { model.stop() }
            try await wait(model)
            XCTAssertNil(model.pendingCapture); XCTAssertNil(model.current)
            XCTAssertNotNil(model.error)
            let problems = try await service.list(); XCTAssertTrue(problems.isEmpty)
        }
    }
    func testMathScreenCanMountWithDynamicTypeAndDarkMode() async throws {
        let service = MathLearningService(store: try store(), directory: try directory())
        let model = MathTutorViewModel(service: service, client: .init(model: MathTestModel()))
        let host = UIHostingController(rootView: NavigationStack { MathTutorView(model: model) }.environment(\.colorScheme, .dark).environment(\.dynamicTypeSize, .accessibility2))
        host.loadViewIfNeeded(); host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844); host.view.layoutIfNeeded()
        XCTAssertNotNil(host.view)
    }
    func testOptInLiveMathematicsPhotoAndTeaching() async throws {
        guard ProcessInfo.processInfo.environment["RUN_MATH_TEACHING_EVALUATION"] == "1" else { throw XCTSkip("Opt-in real API smoke") }
        let key = try XCTUnwrap(ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"])
        let image = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 240)).jpegData(withCompressionQuality: 0.85) { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 900, height: 240))
            ("Find f'(3) for f(x) = x^2." as NSString).draw(at: CGPoint(x: 35, y: 85), withAttributes: [.font: UIFont.systemFont(ofSize: 45), .foregroundColor: UIColor.black])
        }
        let normalized = try XCTUnwrap(PendingAttachment.image(data: image))
        let client = MathTutorClient(model: APIClient(apiKey: key))
        func collect(_ messages: [APIMessage]) async throws -> String {
            var output = ""
            for try await delta in client.stream(messages) {
                if case .content(let text) = delta { output += text }
                if case .finishReason(let reason) = delta { XCTAssertEqual(reason, "stop") }
            }
            XCTAssertFalse(output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            return output
        }
        let transcription = try await collect(MathTutorPrompt.recognition(target: "图片中唯一的一道题，只抄录题目，不解答", image: normalized.dataURL))
        // Deterministic fixture confirmation: not a claim that arbitrary OCR is automatically correct.
        let problem = MathProblemSnapshot(id: UUID(), statement: "求 f(x)=x^2 在 x=3 处的导数。", subject: .calculus, topicID: "calc.derivatives", photoFilename: nil, createdAt: Date(), attempts: [])
        let hint = try await collect(MathTutorPrompt.teaching(problem: problem, mode: .hint, work: "我不知道从哪里开始"))
        let solution = try await collect(MathTutorPrompt.teaching(problem: problem, mode: .solution, work: "请完整解答"))
        if let root = ProcessInfo.processInfo.environment["CLIENT_SMOKE_REPORT_DIR"] {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: root), withIntermediateDirectories: true)
            let report: [String: String] = ["imageOrigin": "UIKit-generated public derivative exercise", "transcription": transcription,
                "hint": hint, "solution": solution, "acceptance": "transport smoke; hint quality requires human review; not a curriculum accuracy benchmark"]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: root).appendingPathComponent("math-teaching-smoke.json"), options: .atomic)
        }
    }
}
