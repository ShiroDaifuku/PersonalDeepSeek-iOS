# DS-002A Bounded Planning Contract

- Goal: validate untrusted planning drafts and coordinate budgeted, cancellable fake query execution before real model integration.
- Dependency: DS-001 integrated at da28a29a04bcd8f6d5cc878f2e0b04637901932c.
- Branch: codex/deepsearch-planning-contract.
- Worktree: D:/daifuku/.worktrees/ds-002a.
- Owner: implementation agent (new Core/Tests files); Lead (control docs/test-only workflow).
- Reviewer: independent reviewer; test agent audits workflow and actual run evidence.
- Allowed code: new ResearchPlanning*.swift and ResearchPlanningTests.swift. ResearchRun version/schema remains unchanged.
- CI scope: add an opt-in research_contract_validation mode to existing registered no-IPA workflow. Preserve full ordinary XCTest and generated-store migration; do not repeat unrelated optional provider/retrieval benchmarks. Default workflow behavior is unchanged. Contract mode overrides integration acceptance to prevent live calls.
- Forbidden: Chat/model/search/provider integration, evidence/claim ledger, Memory/Profile mutation, SwiftData/store I/O, resume/background, new dependencies, production prompts, IPA/main merge/deploy.
- Acceptance: host owns run/conversation binding, stable IDs and validated limits; byte/text/count bounds; query normalization/global dedup with many-to-many question links; valid Codable structure and expected-context validation at use; no empty/dangling entries; reservation before work; failed/cancelled attempts stay charged; actor operation exclusivity; active cancellation/deadline; late results cannot revive terminal runs; successful dispatch ends at evaluating.
- Tests: deterministic fake planner/executor/clock fixtures; Unicode and all bounds; corrupted/future plan; identity; pre-call budget observations; exhausted budgets; failures; cancellation and deadline while suspended; concurrency and dedup. Test helpers avoid inherited XCTest names.
- Status: implementation and independent static review accepted; Simulator verification pending.
- Result: three new Core/Tests files; fourteen deterministic XCTest methods. Review repairs cover evaluating-phase terminalization, explicit conversation binding, Unicode joiner support, extreme Date/Duration deadlines and bounded fixture cleanup. Existing production paths and ResearchRun version remain unchanged.
- Limits: external adapters must cooperate with task cancellation; a structured task-group deadline cannot kill an uncooperative adapter. Fixtures establish structural/scheduling correctness, not question decomposition quality, semantic injection immunity, model cost control or real search success.
- Follow-ups: DS-002B shared APIClient model adapter requires explicit output/token/attempt/deadline accounting; later shared fetch budgeting and evidence stages.
