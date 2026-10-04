# DS-003C retrieval coverage/gap contract validation

Date: 2026-10-04 (Asia/Hong_Kong).
Baseline: 4c108d242bba66c1bb007c91bbb250817d6d63c0.
Tested source: ca33a88582a442c310c17079213d014998f46694 (reviewed compileability repair).
Branch/worktree: codex/deepsearch-coverage-gaps / D:/daifuku/.worktrees/ds-003c.
Workflow: ios-memory-validation.yml with research_contract_validation=true, integration_acceptance=false and research_followup=false.
Run: https://github.com/ShiroDaifuku/PersonalDeepSeek-iOS/actions/runs/37204732728.
Result: repaired source passed actual Simulator retry and independent log audit. First source remains failed and executed no tests/migration.

## Actual Simulator result

- Checkout identifies ca33a88582a442c310c17079213d014998f46694; Xcode16.4 build-for-testing and generated target discovery succeeded.
- Full ordinary XCTest: 313 total, 297 passed, 16 skipped, zero failures.
- ResearchCoverageTests 13/13, 0.077 test seconds (0.093 suite seconds); Ledger16/16, Collection19/19, Run11/11, Planning14/14, APIClientResearchPlanner10/10. All six suite discovery/pass checks succeeded.
- Generated pre-Step-3 store migration: selected test1/1, 0.414 seconds; fixture generation and validation succeeded. This selected fixture is separate from ordinary skipped tests.
- Real API/live integration and optional provider/retrieval evaluations remained disabled. No IPA workflow ran.

Independent log audit accepted the exact source, counts and migration result. Existing diagnostics include unused test variable MemorySemanticPrecisionEvaluation.swift343, widget CFBundleVersion1 versus app17, Simulator destination ambiguity/Actions Node deprecation, and first-launch AppGroup/CoreData missing-directory logs with successful recovery. This is not warning-free runtime or real-device database acceptance.

## Preserved first-run failure

Run 37204438203 remains failed on source 389c3add823f025d6c74a8910f53d18d0d0b198d. Source discovery and generated migration fixture succeeded, but build-for-testing exited65. ResearchCoverage.swift:71 metadataCharacterCost produced “the compiler is unable to type-check this expression in reasonable time.” This is a production-source compileability defect in a nested sum/reduce expression; it is not a failing behavioral assertion, evaluator defect or transport failure. Repair ca33a88582a442c310c17079213d014998f46694 decomposes the same field formula into explicit accumulations and passed independent review. Assertions, metadata cost semantics and production prompts are preserved. Full regression and selected migration passed the new run; the failed run is never relabeled as passing.

## Source and test review

Architecture gate, independent source reviewer and test-design audit approved the final contract before CI. A pre-CI test defect used an old encoded size minus one after changing an embedded byte-limit field; the field's digit shrink could make the new payload fit. It was repaired with an unambiguous margin, preserving production bounds. No failed CI run is implied by that static finding.

ResearchCoverageReport v1 deterministically projects all accepted subquestions into associated sources, page/snippet evidence references, retrieval availability and independent diagnostic gaps. It first checks the supplied ledger against the rebuilt full expected plan/collection/host evidence limits; generic decoded ledger IDs/digests do not bypass that check. A canonical full-ledger SHA256 digest binds report context, including unselected collection/plan changes inherited from ledger context. Hashes establish identity, not authentication or previous accounting.

Limits cover questions (hard max32), retained per-question source reference occurrences (max2048), evidence occurrences (max16384), global source/evidence catalogs (64/512) and full encoded bytes (max2MiB). Early per-row/cumulative reference guards precede graph membership loops. Exceeding report bounds rejects the whole projection; no question is silently dropped.

The existing coordinator requires its already owned ledger and evaluating/finished collection, rechecks original deadline/cancellation before cached return and after construction, reserves new metadata atomically, and caches one fixed configuration. Changed cached limits reject without mutation. Metadata cost counts the new64-character digest, source IDs/origin labels, evidence IDs/source references, every question/reference occurrence, availability and gap labels. No evidence/question body is copied or charged again. Checkpoint v3 and all nine run resources remain unchanged; report generation starts no search/model calls or new round.

## Intended verification

13 new XCTest methods cover shared-query/many-to-many associations, requested aliases with a shared final URL, page/snippet/mixed/empty/metadata-only states, available and absent entry truncation, exact reference ceilings and encoded limits, malformed graphs/enums/digests/future version, forged generic ledger text/truncation, full host context changes, no implicit ledger work, exact metadata delta/idempotence, budget and report-bound atomic failures, changed limits, cancellation and original deadline.

The workflow runs ordinary XCTest without filtering, checks all six research suites executed, and validates a generated pre-Step-3 store migration. Optional live integration/provider/retrieval evaluations are disabled by contract mode.

## Limits of acceptance

- Retrieval associations and page/snippet availability do not establish relevance, answered questions, factual coverage, completeness, contradiction resolution or injection immunity. Gap flags are collection diagnostics, not commands to search or spend model tokens.
- ledgerTruncated means additional truncation of an already bounded selected collection field. No source fetch-success count or original webpage completeness is claimed.
- Generic Codable validates structural bounds only; transferred data must use the expected-host Data wrapper, which checks raw bytes before decoding. No transferred report is adopted by the coordinator.
- Retained output limits do not establish transient heap/download/parser bounds. Synchronous construction uses pre/post deadline checks; it is not forcibly interruptible mid-instruction. Existing DNS IP-pinning/late-timer and post-download page-byte limitations remain separate follow-ups.
- No model refinement, iterative collection, Chat/UI wiring, real source/model quality, durable store/resume/background, IPA, main merge or production deployment is accepted by this increment.

Local per-step logs are retained under ignored .local/ci-logs-37204438203 (failed first run) and .local/ci-logs-37204732728 (successful retry). Final handoff changes documentation only and does not claim a separate CI execution on that documentation commit.
