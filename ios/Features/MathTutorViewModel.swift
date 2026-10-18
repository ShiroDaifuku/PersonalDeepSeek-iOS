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
    }
    func select(_ problem: MathProblemSnapshot) {
        guard !busy, !saving, !importing else { return }
        current = problem; statement = problem.statement; subject = problem.subject; topicID = problem.topicID ?? ""
        photo = nil; reviewed = true; work = ""; output = ""; error = nil
        importing = true
        photoLoad = Task {
            defer { importing = false }
            do {
                let data = try await service.photo(for: problem)
                try Task.checkCancellation()
                if current?.id == problem.id, let data { photo = PendingAttachment(name: "题目原图.jpg", mimeType: "image/jpeg", data: data) }
            } catch is CancellationError { }
            catch { self.error = "原图无法读取：\(error.localizedDescription)；题干仍可使用。" }
        }
    }
    func acceptPhoto(_ data: Data) {
        guard !busy, !saving, current == nil else { return }
        guard let value = PendingAttachment.image(data: data) else { error = "图片解码或压缩失败，请重新选择。"; return }
        photo = value; reviewed = false; error = nil
    }
    func confirm() async {
        guard !busy, !saving, !importing, current == nil, reviewed else { return }
        saving = true; error = nil
        defer { saving = false }
        do {
            current = try await service.create(statement: statement, subject: subject,
                topicID: topicID.isEmpty ? nil : topicID, photo: photo?.data)
            await refresh(); status = "题目已保存；掌握情况尚未评估。"
        } catch { self.error = "保存失败：\(error.localizedDescription)" }
    }
    func recognize() {
        guard !busy, !saving, !importing, current == nil, let photo else { return }
        do { start(messages: try MathTutorPrompt.recognition(target: target, image: photo.dataURL), problem: nil, requestWork: "", requestMode: .hint) }
        catch { self.error = error.localizedDescription }
    }
    func teach() {
        guard !busy, !saving, !importing, let current else { return }
        do { start(messages: try MathTutorPrompt.teaching(problem: current, mode: mode, work: work), problem: current, requestWork: work, requestMode: mode) }
        catch { self.error = error.localizedDescription }
    }
    func stop() { generation?.cancel(); photoLoad?.cancel() }

    private func start(messages: [APIMessage], problem: MathProblemSnapshot?, requestWork: String, requestMode: MathTeachingMode) {
        busy = true; output = ""; error = nil; status = problem == nil ? "正在识别，请稍后核对题干…" : "正在生成教学内容…"
        if problem == nil { reviewed = false }
        let attemptID = UUID()
        generation = Task {
            var buffer = "", lastUpdate = Date.distantPast
            var outcome = MathAttemptStatus.completed
            var failure: String?
            do {
                for try await delta in client.stream(messages) {
                    try Task.checkCancellation()
                    if case .content(let text) = delta {
                        buffer += text
                        guard buffer.count <= (problem == nil ? 12_000 : 32_000) else { throw MathStudyError.outputLimit }
                        if Date().timeIntervalSince(lastUpdate) >= 0.10 {
                            output = buffer; lastUpdate = Date()
                        }
                    }
                    if case .finishReason(let reason) = delta, reason != "stop" { throw MathStudyError.outputLimit }
                }
                try Task.checkCancellation()
                guard !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MathStudyError.emptyResponse }
            } catch {
                let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
                outcome = cancelled ? .cancelled : .failed
                failure = cancelled ? "已停止；保留已收到的部分内容。" : error.localizedDescription
            }
            output = String(buffer.prefix(problem == nil ? 12_000 : 32_000))
            if let problem {
                do {
                    let saved = try await service.store.append(problemID: problem.id, attemptID: attemptID, mode: requestMode,
                        userWork: requestWork, response: output, status: outcome)
                    if current?.id == problem.id { current = saved }
                    await refresh()
                } catch { failure = "教学记录保存失败：\(error.localizedDescription)。请先复制屏幕中的内容。" }
            } else if outcome == .completed {
                statement = output; reviewed = false
            }
            if let failure { error = failure }
            status = problem == nil ? (outcome == .completed ? "识别完成：请核对符号、条件和目标题目后确认。" : "识别未完成；可重试或手动输入题干。") : "本轮结束；未自动评估或更新薄弱点。"
            busy = false
        }
    }
    func delete(_ problem: MathProblemSnapshot) async {
        guard !busy, !saving, !importing else { return }
        saving = true
        do {
            let cleanupWarning = try await service.delete(problem)
            if current?.id == problem.id { current = nil; statement = ""; photo = nil; reviewed = false; output = ""; work = "" }
            await refresh()
            if let cleanupWarning { error = cleanupWarning }
        } catch { self.error = "删除失败：\(error.localizedDescription)" }
        saving = false
    }
}
