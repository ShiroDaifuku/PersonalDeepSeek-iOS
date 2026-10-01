import Foundation

struct ResearchContextBudgetPolicy: Sendable, Equatable {
    var maximumContextCharacters: Int
    var reservedHeadroomCharacters: Int
    var maximumHistoryCharacters: Int
    var maximumEvidenceCharacters: Int
    var maximumPageTextCharactersPerSource: Int
    var maximumSnippetCharactersPerSource: Int
    var maximumTitleCharactersPerSource: Int

    static let chatDefault = ResearchContextBudgetPolicy(
        maximumContextCharacters: 64_000,
        reservedHeadroomCharacters: 16_000,
        maximumHistoryCharacters: 12_000,
        maximumEvidenceCharacters: 26_000,
        maximumPageTextCharactersPerSource: 6_000,
        maximumSnippetCharactersPerSource: 1_200,
        maximumTitleCharactersPerSource: 500
    )

    var maximumInputCharacters: Int {
        max(0, maximumContextCharacters - reservedHeadroomCharacters)
    }
}

struct ResearchHistoryMessage: Sendable, Equatable {
    let role: String
    let content: String
}

struct ResearchContextUsage: Sendable, Equatable {
    let maximumContextCharacters: Int
    let reservedHeadroomCharacters: Int
    let maximumInputCharacters: Int
    let fixedCharacters: Int
    let historyOriginalCharacters: Int
    let historyRetainedCharacters: Int
    let evidenceOriginalCharacters: Int
    let evidenceRetainedCharacters: Int
    let totalRetainedInputCharacters: Int
    let historyOriginalMessageCount: Int
    let historyRetainedMessageCount: Int
    let sourceCount: Int
    let truncatedSourceCount: Int

    var historyTruncatedCharacters: Int {
        max(0, historyOriginalCharacters - historyRetainedCharacters)
    }

    var evidenceTruncatedCharacters: Int {
        max(0, evidenceOriginalCharacters - evidenceRetainedCharacters)
    }

    var wasHistoryTrimmed: Bool {
        historyRetainedCharacters < historyOriginalCharacters ||
            historyRetainedMessageCount < historyOriginalMessageCount
    }

    var wasEvidenceTrimmed: Bool {
        evidenceRetainedCharacters < evidenceOriginalCharacters || truncatedSourceCount > 0
    }
}

struct ResearchContextBudgetResult: Sendable, Equatable {
    let history: [ResearchHistoryMessage]
    let evidenceSources: [ResearchSource]
    let evidencePrompt: String
    let truncatedSourceNumbers: Set<Int>
    let usage: ResearchContextUsage
}

enum ResearchContextBudgetError: LocalizedError, Sendable, Equatable {
    case invalidPolicy
    case mandatoryContentExceedsBudget(requiredCharacters: Int, maximumInputCharacters: Int)
    case fixedContextExceedsBudget(requiredCharacters: Int, maximumInputCharacters: Int)
    case sourceIdentityExceedsBudget(requiredCharacters: Int, availableCharacters: Int)

    var errorDescription: String? {
        switch self {
        case .invalidPolicy:
            "深度研究上下文预算配置无效。"
        case .mandatoryContentExceedsBudget(let required, let maximum):
            "当前请求和必要系统指令共 (required) 字符，超过深度研究输入预算 (maximum) 字符。当前问题未被删除，请缩短请求或附件后重试。"
        case .fixedContextExceedsBudget(let required, let maximum):
            "必要上下文共 (required) 字符，超过深度研究输入预算 (maximum) 字符。请减少本轮附件或历史工具内容后重试。"
        case .sourceIdentityExceedsBudget(let required, let available):
            "搜索来源的标题和地址共 (required) 字符，超过可用研究证据预算 (available) 字符。"
        }
    }
}

enum ResearchContextBudgeter {
    private static let historyTruncationMarker = "\n[history content truncated]"

    static func prepare(
        question: String,
        sources: [ResearchSource],
        history: [ResearchHistoryMessage],
        fixedCharacterCount: Int,
        mandatoryCharacterCount: Int,
        policy: ResearchContextBudgetPolicy = .chatDefault,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) throws -> ResearchContextBudgetResult {
        guard policy.maximumContextCharacters > 0,
              policy.reservedHeadroomCharacters >= 0,
              policy.maximumInputCharacters > 0,
              policy.maximumHistoryCharacters >= 0,
              policy.maximumEvidenceCharacters > 0,
              policy.maximumPageTextCharactersPerSource >= 0,
              policy.maximumSnippetCharactersPerSource >= 0,
              policy.maximumTitleCharactersPerSource > 0,
              fixedCharacterCount >= 0,
              mandatoryCharacterCount >= 0 else {
            throw ResearchContextBudgetError.invalidPolicy
        }
        guard mandatoryCharacterCount <= policy.maximumInputCharacters else {
            throw ResearchContextBudgetError.mandatoryContentExceedsBudget(
                requiredCharacters: mandatoryCharacterCount,
                maximumInputCharacters: policy.maximumInputCharacters
            )
        }
        guard fixedCharacterCount <= policy.maximumInputCharacters else {
            throw ResearchContextBudgetError.fixedContextExceedsBudget(
                requiredCharacters: fixedCharacterCount,
                maximumInputCharacters: policy.maximumInputCharacters
            )
        }

        let availableFlexible = policy.maximumInputCharacters - fixedCharacterCount
        let evidenceLimit = min(policy.maximumEvidenceCharacters, availableFlexible)
        let originalEvidence = LocalResearchService.evidencePrompt(
            question: question,
            sources: sources,
            now: now,
            timeZone: timeZone
        )
        let preparedMetadata = try metadataSources(
            question: question,
            sources: sources,
            evidenceLimit: evidenceLimit,
            policy: policy,
            now: now,
            timeZone: timeZone
        )
        let nonemptySourceNumbers = Set(preparedMetadata.enumerated().compactMap { index, source in
            sources[index].pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : index + 1
        })
        let minimumEvidence = LocalResearchService.evidencePrompt(
            question: question,
            sources: preparedMetadata,
            truncatedSourceNumbers: nonemptySourceNumbers,
            now: now,
            timeZone: timeZone
        )
        guard minimumEvidence.count <= evidenceLimit else {
            throw ResearchContextBudgetError.sourceIdentityExceedsBudget(
                requiredCharacters: minimumEvidence.count,
                availableCharacters: evidenceLimit
            )
        }

        let historyLimit = min(
            policy.maximumHistoryCharacters,
            max(0, availableFlexible - minimumEvidence.count)
        )
        let retainedHistory = selectRecentHistory(history, maximumCharacters: historyLimit)
        let retainedHistoryCharacters = retainedHistory.reduce(0) { $0 + $1.content.count }
        let bodyBudget = min(
            max(0, evidenceLimit - minimumEvidence.count),
            max(0, availableFlexible - minimumEvidence.count - retainedHistoryCharacters)
        )
        let evidenceAllocation = allocatePageText(
            originalSources: sources,
            metadataSources: preparedMetadata,
            totalCharacters: bodyBudget,
            perSourceCeiling: policy.maximumPageTextCharactersPerSource
        )
        let evidencePrompt = LocalResearchService.evidencePrompt(
            question: question,
            sources: evidenceAllocation.sources,
            truncatedSourceNumbers: evidenceAllocation.truncatedSourceNumbers,
            now: now,
            timeZone: timeZone
        )
        let totalRetained = fixedCharacterCount + retainedHistoryCharacters + evidencePrompt.count
        guard totalRetained <= policy.maximumInputCharacters else {
            throw ResearchContextBudgetError.fixedContextExceedsBudget(
                requiredCharacters: totalRetained,
                maximumInputCharacters: policy.maximumInputCharacters
            )
        }

        let historyOriginalCharacters = history.reduce(0) { $0 + $1.content.count }
        let usage = ResearchContextUsage(
            maximumContextCharacters: policy.maximumContextCharacters,
            reservedHeadroomCharacters: policy.reservedHeadroomCharacters,
            maximumInputCharacters: policy.maximumInputCharacters,
            fixedCharacters: fixedCharacterCount,
            historyOriginalCharacters: historyOriginalCharacters,
            historyRetainedCharacters: retainedHistoryCharacters,
            evidenceOriginalCharacters: originalEvidence.count,
            evidenceRetainedCharacters: evidencePrompt.count,
            totalRetainedInputCharacters: totalRetained,
            historyOriginalMessageCount: history.count,
            historyRetainedMessageCount: retainedHistory.count,
            sourceCount: sources.count,
            truncatedSourceCount: evidenceAllocation.truncatedSourceNumbers.count
        )
        return .init(
            history: retainedHistory,
            evidenceSources: evidenceAllocation.sources,
            evidencePrompt: evidencePrompt,
            truncatedSourceNumbers: evidenceAllocation.truncatedSourceNumbers,
            usage: usage
        )
    }

    private static func metadataSources(
        question: String,
        sources: [ResearchSource],
        evidenceLimit: Int,
        policy: ResearchContextBudgetPolicy,
        now: Date,
        timeZone: TimeZone
    ) throws -> [ResearchSource] {
        let unboundedMetadata = sources.map {
            ResearchSource(id: $0.id, title: $0.title, url: $0.url, snippet: $0.snippet)
        }
        let truncatedNumbers = Set(sources.enumerated().compactMap { index, source in
            source.pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : index + 1
        })
        let unboundedPrompt = LocalResearchService.evidencePrompt(
            question: question,
            sources: unboundedMetadata,
            truncatedSourceNumbers: truncatedNumbers,
            now: now,
            timeZone: timeZone
        )
        if unboundedPrompt.count <= evidenceLimit { return unboundedMetadata }

        let capped = sources.map { source in
            ResearchSource(
                id: source.id,
                title: boundedPrefix(source.title, maximum: policy.maximumTitleCharactersPerSource),
                url: source.url,
                snippet: boundedPrefix(source.snippet, maximum: policy.maximumSnippetCharactersPerSource)
            )
        }
        let cappedPrompt = LocalResearchService.evidencePrompt(
            question: question,
            sources: capped,
            truncatedSourceNumbers: truncatedNumbers,
            now: now,
            timeZone: timeZone
        )
        if cappedPrompt.count <= evidenceLimit { return capped }

        let withoutSnippets = capped.map {
            ResearchSource(id: $0.id, title: $0.title, url: $0.url, snippet: "")
        }
        let baseline = LocalResearchService.evidencePrompt(
            question: question,
            sources: withoutSnippets,
            truncatedSourceNumbers: truncatedNumbers,
            now: now,
            timeZone: timeZone
        )
        guard baseline.count <= evidenceLimit else {
            throw ResearchContextBudgetError.sourceIdentityExceedsBudget(
                requiredCharacters: baseline.count,
                availableCharacters: evidenceLimit
            )
        }
        let snippetAllocations = fairAllocations(
            capacities: capped.map { $0.snippet.count },
            total: evidenceLimit - baseline.count
        )
        return capped.enumerated().map { index, source in
            ResearchSource(
                id: source.id,
                title: source.title,
                url: source.url,
                snippet: boundedPrefix(source.snippet, maximum: snippetAllocations[index])
            )
        }
    }

    private static func allocatePageText(
        originalSources: [ResearchSource],
        metadataSources: [ResearchSource],
        totalCharacters: Int,
        perSourceCeiling: Int
    ) -> (sources: [ResearchSource], truncatedSourceNumbers: Set<Int>) {
        let texts = originalSources.map(\.pageText)
        let capacities = texts.map { min($0.count, perSourceCeiling) }
        let allocations = fairAllocations(capacities: capacities, total: totalCharacters)
        var truncated: Set<Int> = []
        let values = metadataSources.enumerated().map { index, source in
            if allocations[index] < texts[index].count { truncated.insert(index + 1) }
            return ResearchSource(
                id: source.id,
                title: source.title,
                url: source.url,
                snippet: source.snippet,
                pageText: boundedPrefix(texts[index], maximum: allocations[index])
            )
        }
        return (values, truncated)
    }

    private static func selectRecentHistory(
        _ history: [ResearchHistoryMessage],
        maximumCharacters: Int
    ) -> [ResearchHistoryMessage] {
        guard maximumCharacters > 0 else { return [] }
        let turns = coherentTurns(history)
        var selected: [[ResearchHistoryMessage]] = []
        var remaining = maximumCharacters
        for turn in turns.reversed() {
            let count = turn.reduce(0) { $0 + $1.content.count }
            if count <= remaining {
                selected.append(turn)
                remaining -= count
                continue
            }
            if selected.isEmpty, remaining > 0 {
                let truncated = truncateTurn(turn, maximumCharacters: remaining)
                if !truncated.isEmpty { selected.append(truncated) }
            }
            break
        }
        return selected.reversed().flatMap { $0 }
    }

    private static func coherentTurns(_ history: [ResearchHistoryMessage]) -> [[ResearchHistoryMessage]] {
        var turns: [[ResearchHistoryMessage]] = []
        var pendingUser: ResearchHistoryMessage?
        for message in history {
            switch message.role {
            case "user":
                if let pendingUser { turns.append([pendingUser]) }
                pendingUser = message
            case "assistant":
                guard let user = pendingUser else { continue }
                turns.append([user, message])
                pendingUser = nil
            default:
                continue
            }
        }
        if let pendingUser { turns.append([pendingUser]) }
        return turns
    }

    private static func truncateTurn(
        _ turn: [ResearchHistoryMessage],
        maximumCharacters: Int
    ) -> [ResearchHistoryMessage] {
        let allocations = fairAllocations(
            capacities: turn.map { $0.content.count },
            total: maximumCharacters
        )
        return turn.enumerated().compactMap { index, message in
            guard allocations[index] > 0 else { return nil }
            return .init(
                role: message.role,
                content: boundedWithMarker(
                    message.content,
                    maximum: allocations[index],
                    marker: historyTruncationMarker
                )
            )
        }
    }

    private static func fairAllocations(capacities: [Int], total: Int) -> [Int] {
        guard !capacities.isEmpty, total > 0 else { return Array(repeating: 0, count: capacities.count) }
        var allocations = Array(repeating: 0, count: capacities.count)
        var remaining = min(total, capacities.reduce(0, +))
        var active = capacities.indices.filter { capacities[$0] > 0 }
        while remaining > 0, !active.isEmpty {
            let share = max(1, remaining / active.count)
            var progressed = false
            for index in active where remaining > 0 {
                let grant = min(share, capacities[index] - allocations[index], remaining)
                if grant > 0 {
                    allocations[index] += grant
                    remaining -= grant
                    progressed = true
                }
            }
            active.removeAll { allocations[$0] >= capacities[$0] }
            if !progressed { break }
        }
        return allocations
    }

    private static func boundedPrefix(_ value: String, maximum: Int) -> String {
        guard maximum > 0 else { return "" }
        return value.count <= maximum ? value : String(value.prefix(maximum))
    }

    private static func boundedWithMarker(_ value: String, maximum: Int, marker: String) -> String {
        guard maximum > 0 else { return "" }
        guard value.count > maximum else { return value }
        guard maximum > marker.count else { return String(value.prefix(maximum)) }
        return String(value.prefix(maximum - marker.count)) + marker
    }
}
