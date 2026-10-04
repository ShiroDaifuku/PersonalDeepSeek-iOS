# DS-003D1 offline refinement contract validation

Date: 2026-10-04 (Asia/Hong_Kong).
Baseline: 49cbda114945a55f106565b7a9a58e81e186bccf.
Tested source: cb7a007ca9dcf77aad9414bcc8d4ab5cc6e3a9ab.
Branch/worktree: codex/deepsearch-refinement-contract / D:/daifuku/.worktrees/ds-003d1.
Simulator run: https://github.com/ShiroDaifuku/PersonalDeepSeek-iOS/actions/runs/37206990585.
Status: first Simulator run succeeded; independent source/test-design review and actual log audit accepted.

## Actual result

Build-for-testing passed. Ordinary XCTest executed 331 tests: 315 passed, 16 opt-in tests skipped, zero failures. ResearchRefinement 18/18, Coverage 13/13, EvidenceLedger 16/16, Collection 19/19, Run 11/11, Planning 14/14 and APIClientResearchPlanner 10/10 passed with no suite skips. Generated-store migration testPreStep3StoreAddsLastConfirmedAtWithoutLosingMemoryOrSource passed 1/1 in 0.453 seconds. Seven suite guards passed. Live embedding/retrieval evaluation steps were skipped intentionally; they are not accepted by this run.

Existing diagnostics remain: unused test value in MemorySemanticPrecisionEvaluation.swift:343, widget CFBundleVersion1 versus parent17, Simulator destination ambiguity and Actions runtime deprecation notices. Initial AppGroup/CoreData missing-path errors were followed by explicit successful store recovery and passing tests; this is not warning-free or a device-store migration claim. No new refinement source warning or failed test was observed.

## Implemented boundary

ResearchRefinementDraft holds bounded, untrusted existing question/gap targets and proposed query strings. Host construction rebuilds the full ledger/coverage against the expected plan/collection and limits before use. Future query IDs are sequential after existing plan IDs; normalization reuses the planning rules. Every repeated normalized candidate and every previously planned query is rejected, including unattempted queries. Both unique query capacity and the original plan's total question-query association capacity bound additions. Empty targets explicitly decline additional work while retaining a bounded metadata-only proposal.

Proposal v1 validates graph, IDs, counts, canonical gap/target order, UTF-8/character and encoded bounds. The expected-host Data wrapper checks raw byte size before decoding and compares a complete rebuilt proposal. The context digest binds immutable run identity/question/createdAt/all nine budget limits/wall time, full coverage (transitively ledger/plan/collection), canonical attempted IDs, limits and the original bounded draft. Ordered resource rows avoid enum-keyed dictionary encoding order instability. Mutable usage/time/phase are excluded because metadata reservation changes them; the coordinator remains lifecycle/accounting authority.

The existing coordinator requires owned ledger/coverage and evaluating finished collection, checks deadline/cancellation before and after construction, and also checks after a correctable construction error. It retains only the validated proposal, never an uncharged raw draft. New query text, digest and every textual ID/gap occurrence are charged once through evidenceCharacters. Identical repeated requests return the cache without another charge; changed raw requests or limits reject without mutation. Ordinary draft errors remain correctable; budget/clock/deadline/cancellation are terminal. Original plan, attempted IDs, collection, ledger and coverage are unchanged. No rounds/queries/planning/HTTP resources are consumed by proposal construction.

## Verification scope

18 new XCTest methods exercise Unicode duplicate and old unattempted query rejection; missing/question-gap references; raw/encoded/text/association ceilings; empty proposals; future version and corrupt graphs; complete host/attempt/draft/limit binding; all nine budgets, wall time, createdAt and dictionary order; forged ledger/report and unselected source text; decoding against post-charge run; exact metadata delta and cache idempotence; correction/conflict; atomic budget failure; original deadline/cancellation and deadline crossed during invalid validation.

Manual ios-memory-validation.yml runs ordinary XCTest without filtering, checks all seven research suites executed and validates one generated pre-Step-3 store migration. Optional live/provider/retrieval evaluation is disabled in contract mode. The IPA workflow is unchanged and only automatically runs for main pushes; task and canonical feature pushes do not trigger it.

## Acceptance limits

- Retrieval gaps describe availability; they do not prove factual insufficiency, relevance, completeness or answer quality. Suggestions do not authorize execution.
- Generic Codable validates structure only; expected-host decoding is required for transferred data. Digests do not authenticate prior execution/accounting history. The coordinator does not adopt transferred proposals.
- Retained representation caps do not bound transient heap, full download or parsing. Synchronous construction is cooperatively checked before/after, not forcibly interrupted mid-instruction.
- DS-003D2 controlled iteration, optional model refinement, live quality, Chat/UI, persistence/resume/background, IPA/main merge and production deployment remain outside this increment. Checkpoint remains v3.

Actual per-step CI logs are retained in ignored .local/ci-logs-37206990585. Final documentation handoff does not claim a separate CI execution on its documentation commit; source and workflow remain identical to the tested source.
