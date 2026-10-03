# Architecture decisions

## ADR-001: ResearchRun independent from AgentRunner

Context: native tools are accepted infrastructure; Research is single-pass. Decision: ResearchRun owns long workflows and budgets; AgentRunner retains ordinary native protocol. Alternative: inflate AgentLoopBudget and embed research there. Reason: different lifecycle and evidence responsibilities. Consequence: reuse shared search/transport; no duplicate runtime or protocol parser.

## ADR-002: Research state separate from tool audit

Context: ToolExecutionRecord contains bounded conversation audit/history. Decision: plans, evidence, claims and checkpoints belong to research state/store; audit may later store a bounded reference. Alternative: full research state in tool envelopes. Reason: preserve audit scope and prevent prompt/store growth. Consequence: foundation DTO is not a SwiftData model; storage/migration is a later increment.

## ADR-003: Validate checkpoints before use

Context: restored state is untrusted input and unit correctness must not require network. Decision: explicit time/budgets and validated versioned Codable state. Reject corrupted/future checkpoints. Alternative: unchecked mutable/synthesized DTOs. Reason: lifecycle and cumulative budget correctness. Consequence: serialization is not persistence or resume execution; no raw evidence, secrets, planner calls or Memory mutation in DS-001.

## ADR-004: Untrusted draft and host-owned planning contract

Context: a planner must not own permissions, run binding, budget or accepted plan IDs. Decision: bounded draft text is validated and normalized into a host-owned plan with stable IDs and global query deduplication/many-to-many question associations. Plan decoding checks structure; use checks expected ResearchRun binding. Alternative: accept model IDs/control fields or only validate at initial construction. Reason: keep configuration and state authoritative and prevent corrupt checkpoints bypassing limits. Consequence: DS-002A proves structural and fixture coordination correctness only; DS-002B adds the shared model adapter after explicit accounting.

## ADR-005: Cumulative reservations and cooperative async deadlines

Context: actor methods reenter across awaits; late callbacks and resource resets can violate research lifecycle. Decision: reject overlapping operations before awaiting, reserve work before calls, actively race remaining wall deadline and cancellation, preserve terminal state and attempted-work usage. Alternative: only check time before calling an adapter. Reason: bound cooperative async execution and prevent duplicate work or resurrection after cancellation. Consequence: dependency adapters must honor task cancellation; structured concurrency cannot forcibly terminate an uncooperative adapter. Successful DS-002A query dispatch stops at evaluating, not completed.

## ADR-006: Reserve planning output before one shared transport attempt

Context: default Chat transport retries HTTP and has no explicit output cap; ResearchRun v1 cannot represent planning attempts/tokens. Decision: opt-in shared APIClient controls, exactly one planner attempt, full output ceiling reserved together with its round, separate input/raw-response/content byte caps, no refunds. Checkpoint v2 adds planningAttempts/planningTokens and rejects v1 rather than inventing history. Alternative: reuse synthesis budget, hide retries, or fill old checkpoints with new zero counters. Reason: preserve independently accounted cumulative work. Consequence: token allocation is conservative output capacity, not actual billing; no persistent ResearchRun migration or Chat behavior change. Live planner quality is a later evaluation.

## ADR-007: Admit shared collection requests through the existing run owner

Context: opaque gather hides fallback/page attempts and swallows page failures; default search transport may follow redirects implicitly. Decision: opt-in shared request admission, explicit search metadata and noRedirect accounted search; existing coordinator owns cumulative logical query/search HTTP/page hop counters and token-scoped admission. Retained source/text reservations are atomic and snapshots bounded. Checkpoint v3 adds searchRequests and rejects missing historical authority. Alternative: parallel run actors, a second search stack or counting only successful providers/pages. Reason: retain authoritative budgets and stop late work after terminal outcomes. Consequence: default Chat/tool behavior stays unchanged, transient collection is not an evidence ledger, and existing DNS/download limitations remain separate follow-ups.
