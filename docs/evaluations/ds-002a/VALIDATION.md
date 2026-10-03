# DS-002A validation history

Date: 2026-10-03 (Asia/Hong_Kong). Status: PASS; independent review accepted and actual Simulator verification succeeded.

## Reviewed scope

Bounded untrusted planning drafts, host-owned immutable plans with stable IDs and expected-context validation, global query deduplication/associations, and an injected fixture coordinator. Round/query reservations precede attempted work and remain charged on failure/cancellation. Cooperative deadlines and cancellation cannot revive terminal runs; successful fixture dispatch stops at evaluating. Fourteen new deterministic XCTest methods. ResearchRun schema/version, Chat, shared API/SSE/search runtime, Memory/Profile, SwiftData and production prompts remain unchanged.

Independent architecture, source and workflow review accepted this scope. Workflow mode research_contract_validation=true preserves unfiltered ordinary XCTest and generated old-schema migration, requires explicit Run/Planning suite discovery, and skips optional provider/retrieval benchmarks. It overrides integration acceptance even when that input is true. No live model secret, network acceptance, IPA packaging or production deployment is selected.

## First run: failed, retained

- Run: https://github.com/ShiroDaifuku/PersonalDeepSeek-iOS/actions/runs/37122839222
- Source: 706e35e517657da93a290e8ad0e7c51b93beeb2c.
- Build and generated Research source presence passed. Ordinary XCTest: 254 total, 16 skipped, one failure. Planning 14/14 and Run 10/10 passed without skips. Post-test discovery and migration did not execute after the failure.
- Failure: unchanged LocalResearchTests.testSystemDNSResolverTimeoutReturnsWithoutWaitingForBlockingLookup, line 132, returned lookup success; test duration 13.898 seconds.
- Classification: existing scheduling-sensitive fixture. A 0.25-second blocking lookup raced a 0.02-second utility-queue timer. Delayed scheduling can change the winner; logs do not prove the precise scheduling sequence. No DS-002A production defect was demonstrated.
- Repair: replace fixed sleeps in timeout/cancellation fixtures with explicit blocked-lookup gates. Completion must occur while lookup remains blocked, with the same exact timeout/cancellation error assertions; bounded expectation watchdogs fail rather than hang, and gates release before task cleanup. Cancellation additionally waits for lookup entry. Independent review accepted the test-only repair.
- Separate production limitation: existing DNS first-callback-wins does not check the original deadline before accepting lookup success. Define monotonic deadline semantics and reject late success in a separate task. This test repair does not fix that limitation.

## Follow-up run

- Run: https://github.com/ShiroDaifuku/PersonalDeepSeek-iOS/actions/runs/37123424473
- Source: 43dd89a34bc4f62f03f49a5c65e1c88bfe030ba2.
- Workflow: ios-memory-validation.yml; integration_acceptance=false, research_followup=false, research_contract_validation=true.
- Result: SUCCESS, source SHA and branch verified through GitHub API and downloaded logs. Xcode 16.4 build passed. Ordinary XCTest: 254 total, 238 passed, 16 skipped, zero failures. Planning 14/14 and Run 10/10 passed without skips; explicit suite discovery succeeded. Both DNS timeout/cancellation fixtures passed while lookup was blocked. Selected generated pre-Step-3 migration passed 1/1.
- Optional embedding/retrieval benchmark steps were skipped by contract mode. Ordinary tests retain their existing 16 opt-in skips; no production assertions/prompts were relaxed. Independent test agent audits the same downloaded evidence.
- Existing build warnings: unused `test` at MemorySemanticPrecisionEvaluation.swift:343 and extension CFBundleVersion 1 versus parent app 17. No new Research planning compile warnings/errors. Simulator initial store creation emitted missing-directory CoreData diagnostics; ordinary suite and separate generated-store migration passed. This does not establish physical-device database behavior.
- Final handoff commit is documentation/evidence only; tested Core/Tests/workflow content remains at 43dd89a. No additional executable test run is claimed for that documentation commit.

## Scope limitations

Fixtures validate structural and scheduling contracts, not decomposition quality, semantic injection immunity, real search results or model cost control. Adapters must cooperate with cancellation; structured concurrency cannot kill an uncooperative adapter. Generic Codable validation is structural; consumers must use expected-context validation. Plans are not persisted or authenticated, and no relaunch/resume is implemented. DS-002B requires explicit shared APIClient output/token/attempt/deadline accounting before live planning. Shared fetch attempts and evidence accounting remain later work.
