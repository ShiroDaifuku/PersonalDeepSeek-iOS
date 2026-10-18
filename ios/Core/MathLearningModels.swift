import Foundation
import SwiftData

// Mathematics is intentionally a separate domain/store, not a MemoryItem kind.
enum MathStudyScope { static let local = "local-default" }

enum MathSubject: String, Codable, CaseIterable, Sendable, Identifiable {
    case calculus, linearAlgebra, probability
    var id: String { rawValue }
    var title: String {
        switch self { case .calculus: "高等数学"; case .linearAlgebra: "线性代数"; case .probability: "概率论与数理统计" }
    }
}

enum MathTeachingMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case hint, nextStep, solution, checkWork
    var id: String { rawValue }
    var title: String {
        switch self { case .hint: "一点提示"; case .nextStep: "下一步引导"; case .solution: "完整解答"; case .checkWork: "检查我的步骤" }
    }
}

enum MathAttemptStatus: String, Codable, Sendable { case completed, cancelled, failed }

struct MathTopic: Identifiable, Sendable {
    let id: String
    let subject: MathSubject
    let title: String
}

enum MathSyllabus {
    // Coarse navigation taxonomy, not an assertion of the latest official syllabus.
    static let topics: [MathTopic] = [
        .init(id: "calc.limits", subject: .calculus, title: "极限与连续"),
        .init(id: "calc.derivatives", subject: .calculus, title: "一元函数微分学"),
        .init(id: "calc.integrals", subject: .calculus, title: "一元函数积分学"),
        .init(id: "calc.geometry", subject: .calculus, title: "空间解析几何与向量代数"),
        .init(id: "calc.multivariable", subject: .calculus, title: "多元函数微分学"),
        .init(id: "calc.multiple-integrals", subject: .calculus, title: "重积分"),
        .init(id: "calc.curve-surface", subject: .calculus, title: "曲线积分与曲面积分"),
        .init(id: "calc.series", subject: .calculus, title: "无穷级数"),
        .init(id: "calc.ode", subject: .calculus, title: "常微分方程"),
        .init(id: "linear.determinants", subject: .linearAlgebra, title: "行列式"),
        .init(id: "linear.matrices", subject: .linearAlgebra, title: "矩阵与秩"),
        .init(id: "linear.vectors", subject: .linearAlgebra, title: "向量与线性相关"),
        .init(id: "linear.systems", subject: .linearAlgebra, title: "线性方程组"),
        .init(id: "linear.eigen", subject: .linearAlgebra, title: "特征值与特征向量"),
        .init(id: "linear.quadratic", subject: .linearAlgebra, title: "二次型"),
        .init(id: "prob.events", subject: .probability, title: "随机事件与概率"),
        .init(id: "prob.variables", subject: .probability, title: "随机变量及分布"),
        .init(id: "prob.joint", subject: .probability, title: "多维随机变量"),
        .init(id: "prob.moments", subject: .probability, title: "数字特征"),
        .init(id: "prob.limits", subject: .probability, title: "大数定律与中心极限定理"),
        .init(id: "prob.statistics", subject: .probability, title: "数理统计基础"),
        .init(id: "prob.estimation", subject: .probability, title: "参数估计"),
        .init(id: "prob.testing", subject: .probability, title: "假设检验")
    ]
}

@Model final class MathProblem {
    @Attribute(.unique) var id: UUID
    var scopeID: String
    var statement: String
    var subjectRawValue: String
    var topicID: String?
    var photoFilename: String?
    var confirmedAt: Date
    var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \MathAttempt.problem) var attempts: [MathAttempt]
    @Relationship(deleteRule: .cascade, inverse: \MathLearningEvidence.problem) var evidence: [MathLearningEvidence]
    init(id: UUID, statement: String, subject: MathSubject, topicID: String?, photoFilename: String?) {
        self.id = id; scopeID = MathStudyScope.local; self.statement = statement
        subjectRawValue = subject.rawValue; self.topicID = topicID; self.photoFilename = photoFilename
        confirmedAt = Date(); createdAt = confirmedAt; attempts = []; evidence = []
    }
}

@Model final class MathAttempt {
    @Attribute(.unique) var id: UUID
    var scopeID: String
    var modeRawValue: String
    var userWork: String
    var response: String
    var statusRawValue: String
    var createdAt: Date
    var problem: MathProblem?
    init(id: UUID, mode: MathTeachingMode, userWork: String, response: String, status: MathAttemptStatus, problem: MathProblem) {
        self.id = id; scopeID = MathStudyScope.local; modeRawValue = mode.rawValue
        self.userWork = userWork; self.response = response; statusRawValue = status.rawValue
        createdAt = Date(); self.problem = problem
    }
}

@Model final class MathKnowledgePoint {
    @Attribute(.unique) var id: String
    var scopeID: String
    var subjectRawValue: String
    var title: String
    // No mastery score is computed in Steps 1–2.
    var createdAt: Date
    init(topic: MathTopic) {
        id = topic.id; scopeID = MathStudyScope.local; subjectRawValue = topic.subject.rawValue
        title = topic.title; createdAt = Date()
    }
}

@Model final class MathLearningEvidence {
    @Attribute(.unique) var id: UUID
    var scopeID: String
    var topicID: String
    var sourceAttemptID: UUID
    var note: String
    var createdAt: Date
    var problem: MathProblem?
    // Reserved storage only: no AI inference writes evidence in Steps 1–2.
    init(topicID: String, sourceAttemptID: UUID, note: String, problem: MathProblem) {
        id = UUID(); scopeID = MathStudyScope.local; self.topicID = topicID
        self.sourceAttemptID = sourceAttemptID; self.note = note; self.problem = problem; createdAt = Date()
    }
}

struct MathAttemptSnapshot: Codable, Sendable, Identifiable, Equatable {
    let id: UUID
    let mode: MathTeachingMode
    let userWork: String
    let response: String
    let status: MathAttemptStatus
    let createdAt: Date
}

struct MathProblemSnapshot: Codable, Sendable, Identifiable, Equatable {
    let id: UUID
    let statement: String
    let subject: MathSubject
    let topicID: String?
    let photoFilename: String?
    let createdAt: Date
    let attempts: [MathAttemptSnapshot]
}
