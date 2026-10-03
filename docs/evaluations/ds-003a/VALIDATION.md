# DS-003A validation history

Date: 2026-10-03 (Asia/Hong_Kong). Status: PASS; independent source/test review accepted and actual Simulator verification succeeded.

## Reviewed scope

Existing ResearchPlanningCoordinator remains the only ResearchRun owner. It collects its own accepted plan through shared LocalResearchService, with operation exclusivity, original wall deadline, token-scoped admission and late-result rejection. Logical queries, provider HTTP attempts and page hops have separate counters. Hook-origin errors propagate across Brave fallback and page snippet fallback; control errors cannot become snippets. Admitted failed/cancelled attempts remain charged.

ResearchRun checkpoint v3 adds searchRequests and requires all nine budget/usage dimensions. It rejects v1/v2/future versions explicitly, preserving no invented history. No persistent research store or migration is introduced; the existing SwiftData generated-store regression remains a separate test.

Transient snapshots bind immutable run/conversation IDs, stable source IDs and unique query links. Requested URL identity lowercases scheme/host and removes fragment/default port while preserving path/query/encoding. Repeated requested keys are not refetched; distinct redirect aliases can remain separate. Sources, every retained textual field and additional query associations reserve atomically before retention. UTF-8 and character caps cover retained fields; URL identity is rejected rather than truncated. Full source slots skip new candidates before fetch; duplicates can still add bounded associations. Page errors may retain marked untrusted snippets; no-results can produce an empty evaluating snapshot. Neither outcome completes research.

Accounted search uses a separate noRedirect shared transport; ordinary search/gather/fetch defaults stay intact. Existing manual page redirects require admission for every HTTP hop. Tests verify actual factory/session/delegate wiring, refusal callback and offline 302 handling. Custom URLProtocol does not exercise a real automatic redirect event; live provider behavior is not established. Injected fetchers must perform one application request without hidden retries/redirects. Counters are application work, not TCP/DNS retries or billing.

Independent architecture, source and test/workflow static reviews accepted the scope. Nineteen new ResearchCollectionTests cover fallback/hop precharge, rejected admission, dedup/links/bounds, atomic source/text retention, snippets, noRedirect wiring/default isolation, late search/page results, cancellation/deadline/overlap/idempotence, clock control errors and source identity. ResearchRunTests adds per-resource isolated v3 corruption checks. No local Swift/Xcode exists on Windows; static acceptance does not replace execution.

## Simulator run

- Run: https://github.com/ShiroDaifuku/PersonalDeepSeek-iOS/actions/runs/37132615814
- Source: c2f881f636551c136fc6d8ecd1eedac948f666d0.
- Workflow: ios-memory-validation.yml; integration_acceptance=false, research_followup=false, research_contract_validation=true.
- Selected path: unfiltered ordinary XCTest, explicit Run/Planning/model-planner/collection suite discovery, generated old-store migration. Optional provider/retrieval benchmarks and live acceptance are excluded; all new search/page tests use injected offline fixtures. No IPA, release or deployment.
- Result: SUCCESS on the first run. Branch/source verified through GitHub API and downloaded checkout log. Xcode 16.4 build passed; ordinary XCTest 284 total, 268 passed, 16 skipped, zero failures. Collection 19/19, Run 11/11, Planning 14/14 and model planner 10/10 passed without skips. Explicit source and suite discovery succeeded. Selected generated pre-Step-3 migration passed 1/1 in 0.595 seconds.
- Late page cancellation/deadline and admission propagation cases executed and passed; no assertions or production prompts were relaxed. Independent test agent audits the downloaded logs, including opt-in skips and source identity.
- Existing build warnings remain: unused `test` at MemorySemanticPrecisionEvaluation.swift:343 and extension CFBundleVersion 1 versus parent app 17. Simulator startup may emit initial store creation/missing-directory diagnostics; ordinary suite and generated-store migration passed. Runtime/tooling logs are not claimed warning-free or physical-device evidence.
- Independent log audit confirmed initial AppGroup missing-directory recovery succeeded and no new collection compiler diagnostics. Actions reports existing Node 20 deprecation/forced Node 24 tooling notices.
- Optional provider/retrieval benchmarks and live acceptance were skipped. No paid/live provider requests, IPA/archive, release or production deployment was selected.
- Final handoff changes are documentation/evidence only; tested executable/workflow content remains c2f881f. No additional test run is claimed for that documentation commit. No failed CI run occurred in DS-003A; prior DS-001/002A failures remain in their own records.

## Limits and next stage

This is bounded in-memory collection, not an evidence/claim ledger, durable checkpoint storage, gap analysis, synthesis, Chat integration or resume. Raw material is untrusted and does not update Memory/Profile. Existing DNS IP-pinning/late-success semantics and post-download page byte checks remain unresolved; response download, transient search parsing and large-grapheme allocation are not covered by retained-field memory bounds. Fixtures do not establish live provider/search/model quality or device behavior. Cooperative cancellation remains required. DS-003B will define bounded evidence identity/associations and later coverage/gaps/refinement.
