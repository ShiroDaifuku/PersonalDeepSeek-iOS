# DS-003B evidence ledger validation

Date: 2026-10-04 (Asia/Hong_Kong).

Source: 202047883869a75cae77f0958f84fdf17dfe12b5.
Baseline: ee290e1505c3061fccadd2151041b71614e3139d.
Branch/worktree: codex/deepsearch-evidence-ledger / D:/daifuku/.worktrees/ds-003b.
Simulator workflow: ios-memory-validation.yml with research_contract_validation=true, integration_acceptance=false and research_followup=false.
Run: https://github.com/ShiroDaifuku/PersonalDeepSeek-iOS/actions/runs/37140273860.
Result: first run succeeded on the exact source above; no repair or rerun required. Independent actual-log audit accepted checkout SHA and results.

## Actual Simulator result

- Xcode 16.4 build-for-testing succeeded; new Core/Test files were discovered in generated targets.
- Full ordinary XCTest: 300 total, 284 passed, 16 skipped, zero failures.
- ResearchEvidenceLedgerTests: 16/16, 0.073 test seconds (0.306 suite seconds).
- Existing research suites: Collection 19/19, Run 11/11, Planning 14/14, APIClientResearchPlanner 10/10; all five explicit suite-pass checks succeeded.
- Generated pre-Step-3 store migration: selected test 1/1, 0.552 seconds; fixture generation and validation succeeded.
- Live integration and optional embedding/retrieval evaluations were skipped by the research contract input. No real API keys were injected for these tests.

Actual per-step logs are retained locally under .local/ci-logs-37140273860 (ignored); source checkout and GitHub run head identify the tested commit. Final handoff is documentation only and does not claim a separate CI execution.

Existing diagnostics: MemorySemanticPrecisionEvaluation.swift:343 unused test variable; widget CFBundleVersion 1 versus app 17; Simulator destination ambiguity and Actions Node deprecation. Initial AppGroup/CoreData directory errors recovered successfully before passing tests. This result is not warning-free runtime or real-device database verification.

## Source review

Independent architecture, source reviewer and validation agent approved the bounded offline contract before CI. Review found that projection equality alone missed unprojected accepted-plan text. Full sorted-key JSON SHA256 plan and collection context digests close that binding gap. Tests exercise same-UUID plan text changes, unused snippet changes and underlying source UUID changes. Hashes are context identity, not authentication.

The same coordinator builds only from its accepted plan and charged finished collection in evaluating. It checks original wall deadline and cancellation, reserves new metadata before caching, and rejects changed cached limits without mutating the run. Cumulative source/body charges are reused. Both 64-character digests add 128 metadata characters even to an empty ledger; question associations, first-observation query/origin and entry/source reference IDs add further charges. Numeric fields and JSON envelope are bounded by encoded bytes; the character budget is not a heap/billing meter. ResearchRun checkpoint remains v3 with nine unchanged resources.

## Intended checks

Full ordinary XCTest, explicit discovery/pass checks for all five research suites, and generated pre-Step-3 store migration. The new ledger suite has 16 test methods covering stable IDs and provenance, page/snippet selection, requested aliases, Unicode segment bounds/offsets, global/source/entry/encoded limits, corrupt and cross-context decoding, exact metadata delta, atomic budget failure, idempotence, changed limits, empty results, cancellation and original deadline.

## Practical limits

- This is an ephemeral offline component. No Chat/UI integration, coverage/gap evaluator, claim/citation support, real provider/model quality, durable store or resume execution is accepted.
- Query/question associations describe retrieval provenance, not relevance, truth, contradiction resolution or semantic injection immunity.
- The known provider applies only to the first observed query; later query observations have unknown providers. Distinct requested aliases remain distinct even with one final URL.
- Segment offsets refer to the selected already-bounded collection field. Whitespace edges are omitted; truncation flags record additional ledger prefix loss, not completeness of the original webpage.
- Whole-ledger encoded-byte or source-cap exhaustion rejects construction; entry/text caps truncate selected prefixes explicitly. Retained limits do not bound all transient allocations or full downloads/search parsing. Synchronous projection cannot be interrupted mid-instruction; pre/post checks preserve the original deadline before publication.
- Generic Codable validates structure only. Transferred input must use the Data wrapper with expected host plan, collection and limits. No decoded ledger is adopted into the coordinator and serialization is not authenticated accounting history.
- Existing DNS IP-pinning/late-timer and post-download page-byte limitations remain separate follow-ups.

No IPA workflow, real API evaluation, main merge, release or production deployment is part of this validation.
