import Foundation
import SwiftUI

@MainActor final class MathTutorViewModel: ObservableObject {
    @Published var problems: [MathProblemSnapshot] = []
    @Published var current: MathProblemSnapshot?
    @Published var statement = ""
    @Published var subject = MathSubject.calculus
    @Published var topicID = ""
    @Published var target = "只识别第 1 题；包含它的全部小问"
    @Published var mode = MathTeachingMode.hint
    @Published var work = ""
    @Published var photo: PendingAttachment?
    @Published var capturePhotos: [PendingAttachment] = []
    @Published var capture: MathCapture?
    @Published var pendingCapture: MathCapture?
    @Published var editingCapture = false
    @Published var reviewed = false
    @Published var busy = false
    @Published var saving = false
    @Published var importing = false
    @Published var output = ""
    @Published var error: String?
    @Published var status = ""
    let service: MathLearningService
    private let client: MathTutorClient
    private var generation: Task<Void, Never>?
    private var photoLoad: Task<Void, Never>?
    init(service: MathLearningService, client: MathTutorClient = .init()) { self.service = service; self.client = client }

    func refresh() async {
        do { problems = try await service.list() } catch { self.error = "读取数学档案失败：\(error.localizedDescription)" }
    }
    func newProblem() {
        guard !busy, !saving, !importing else { return }
        current = nil; statement = ""; photo = nil; reviewed = false; work = ""; output = ""; error = nil; status = ""; topicID = ""
        capture = nil; pendingCapture = nil; capturePhotos = []; editingCapture = false
    }
    func select(_ problem: MathProblemSnapshot) {
        guard !busy, !saving, !importing else { return }
        current = problem; statement = problem.statement; subject = problem.subject; topicID = problem.topicID ?? ""
        photo = nil; reviewed = true; work = ""; output = ""; error = nil
        capture = nil; pendingCapture = nil; capturePhotos = []; editingCapture = false
        importing = true
        photoLoad = Task {
            defer { importing = false }
            do {
                let data = try await service.photo(for: problem)
                try Task.checkCancellation()
                if current?.id == problem.id, let data { photo = PendingAttachment(name: "题目原图.jpg", mimeType: "image/jpeg", data: data) }
                let archive = try await service.captures(for: problem)
                if current?.id == problem.id {
                    capture = archive?.records.last?.capture
                    work = capture?.studentWork ?? ""
                }
            } catch is CancellationError { }
            catch { self.error = "原图无法读取：\(error.localizedDescription)；题干仍可使用。" }
        }
    }
    func acceptPhoto(_ data: Data) {
        guard !busy, !saving else { return }
        guard let value = PendingAttachment.image(data: data) else { error = "图片解码或压缩失败，请重新选择。"; return }
        acceptPhotos([value])
    }
    func acceptPhotos(_ values: [PendingAttachment]) {
        guard !busy, !saving, (1...6).contains(values.count) else { return }
        capturePhotos = values
        if current == nil { photo = values.first; statement = ""; work = ""; capture = nil }
        pendingCapture = nil; reviewed = false; error = nil; output = ""; editingCapture = false
    }
    func confirmCapture() async {
        guard !busy, !saving, !importing, var value = pendingCapture else { return }
        error = nil
        value.statement = current?.statement ?? statement
        value.studentWork = work
        do {
            _ = try value.validated()
            if let current {
                saving = true
                defer { saving = false }
                try await service.appendCapture(value, images: capturePhotos.map(\.data), for: current)
                capture = value; pendingCapture = nil; output = ""; status = "解题过程已保存。"
            } else {
                capture = value; reviewed = true
                await confirm()
                if current != nil { pendingCapture = nil; output = "" }
            }
        } catch { self.error = "保存图片识别结果失败：\(error.localizedDescription)" }
    }
    func confirm() async {
        guard !busy, !saving, !importing, current == nil, reviewed else { return }
        saving = true; error = nil
        defer { saving = false }
        do {
            current = try await service.create(statement: statement, subject: subject,
                topicID: topicID.isEmpty ? nil : topicID, photo: photo?.data,
                capture: capture, images: capturePhotos.map(\.data))
            await refresh(); status = "题目已保存；掌握情况尚未评估。"
        } catch { self.error = "保存失败：\(error.localizedDescription)" }
    }
    func recognize() {
        guard !busy, !saving, !importing else { return }
        let images = capturePhotos.isEmpty ? photo.map { [$0] } ?? [] : capturePhotos
        guard !images.isEmpty else { return }
        do { start(messages: try MathTutorPrompt.recognition(target: target, images: images.map(\.dataURL), knownStatement: current?.statement), problem: nil, requestWork: "", requestMode: .hint) }
        catch { self.error = error.localizedDescription }
    }
    func teach() {
        guard !busy, !saving, !importing, pendingCapture == nil, let current else { return }
        do { start(messages: try MathTutorPrompt.teaching(problem: current, mode: mode, work: work, capture: capture), problem: current, requestWork: work, requestMode: mode) }
        catch { self.error = error.localizedDescription }
    }
    func stop() { generation?.cancel(); photoLoad?.cancel() }

    private func start(messages: [APIMessage], problem: MathProblemSnapshot?, requestWork: String, requestMode: MathTeachingMode) {
        busy = true; output = ""; error = nil; status = problem == nil ? "正在读取题目与已有解题过程…" : "正在生成教学内容…"
        if problem == nil { reviewed = false; pendingCapture = nil }
        let attemptID = UUID()
        generation = Task {
            var buffer = "", lastUpdate = Date.distantPast
            var count = StreamingCharacterCount()
            var outcome = MathAttemptStatus.completed
            var failure: String?
            do {
                for try await delta in client.stream(messages) {
                    try Task.checkCancellation()
                    if case .content(let text) = delta {
                        buffer += text
                        count.append(text)
                        guard count.count <= (problem == nil ? 36_000 : 32_000) else { throw MathStudyError.outputLimit }
                        if problem != nil, Date().timeIntervalSince(lastUpdate) >= 0.10 {
                            output = buffer; lastUpdate = Date()
                        }
                    }
                    if case .finishReason(let reason) = delta, reason != "stop" { throw MathStudyError.outputLimit }
                }
                try Task.checkCancellation()
                guard !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MathStudyError.emptyResponse }
                if problem == nil {
                    var value = try MathCapture.decode(buffer)
                    if let current { value.statement = current.statement }
                    pendingCapture = value; statement = value.statement; work = value.studentWork
                }
            } catch {
                let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
                outcome = cancelled ? .cancelled : .failed
                failure = cancelled ? "已停止；保留已收到的部分内容。" : error.localizedDescription
            }
            output = problem == nil ? "" : String(buffer.prefix(32_000))
            if let problem {
                do {
                    let saved = try await service.store.append(problemID: problem.id, attemptID: attemptID, mode: requestMode,
                        userWork: requestWork, response: output, status: outcome)
                    if current?.id == problem.id { current = saved }
                    await refresh()
                } catch { failure = "教学记录保存失败：\(error.localizedDescription)。请先复制屏幕中的内容。" }
            }
            if let failure { error = failure }
            status = problem == nil ? (outcome == .completed ? "识别完成，请核对下方公式与解题过程。" : "识别未完成；请重试，原档案未变动。") : "本轮结束；未自动评估或更新薄弱点。"
            busy = false
        }
    }
    func delete(_ problem: MathProblemSnapshot) async {
        guard !busy, !saving, !importing else { return }
        saving = true
        do {
            let cleanupWarning = try await service.delete(problem)
            if current?.id == problem.id {
                current = nil; statement = ""; photo = nil; reviewed = false; output = ""; work = ""
                capture = nil; pendingCapture = nil; capturePhotos = []
            }
            await refresh()
            if let cleanupWarning { error = cleanupWarning }
        } catch { self.error = "删除失败：\(error.localizedDescription)" }
        saving = false
    }
}
