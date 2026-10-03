# Architecture decisions

## ADR-001: ResearchRun independent from AgentRunner

Context: native tools are accepted infrastructure; Research is single-pass. Decision: ResearchRun owns long workflows and budgets; AgentRunner retains ordinary native protocol. Alternative: inflate AgentLoopBudget and embed research there. Reason: different lifecycle and evidence responsibilities. Consequence: reuse shared search/transport; no duplicate runtime or protocol parser.

## ADR-002: Research state separate from tool audit

Context: ToolExecutionRecord contains bounded conversation audit/history. Decision: plans, evidence, claims and checkpoints belong to research state/store; audit may later store a bounded reference. Alternative: full research state in tool envelopes. Reason: preserve audit scope and prevent prompt/store growth. Consequence: foundation DTO is not a SwiftData model; storage/migration is a later increment.

## ADR-003: Validate checkpoints before use

Context: restored state is untrusted input and unit correctness must not require network. Decision: explicit time/budgets and validated versioned Codable state. Reject corrupted/future checkpoints. Alternative: unchecked mutable/synthesized DTOs. Reason: lifecycle and cumulative budget correctness. Consequence: serialization is not persistence or resume execution; no raw evidence, secrets, planner calls or Memory mutation in DS-001.
