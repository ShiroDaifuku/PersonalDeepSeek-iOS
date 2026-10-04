# DS-003D2 controlled iterative collection validation

Date: 2026-10-04 (Asia/Hong_Kong).
Baseline: ae9217a5dde87c88975c3f13f309c3ad0a3636ca.
Branch/worktree: codex/deepsearch-controlled-iteration / D:/daifuku/.worktrees/ds-003d2.
Tested source: 1b36440c7a89cecf352d0e867f67d639a389ad8f.
Simulator run: https://github.com/ShiroDaifuku/PersonalDeepSeek-iOS/actions/runs/37208933293.
Status: first Simulator run succeeded; independent architecture/source/test-design and actual log audit accepted.

## Actual result

Build-for-testing passed. Ordinary XCTest executed 352 tests: 336 passed, 16 opt-in tests skipped, zero failures. ResearchIteration21/21, Refinement18/18, Coverage13/13, EvidenceLedger16/16, Collection19/19, Run11/11, Planning14/14 and APIClientResearchPlanner10/10 passed with no suite skips. Eight discovery guards passed. The separate generated-store testPreStep3StoreAddsLastConfirmedAtWithoutLosingMemoryOrSource passed1/1 in0.636 seconds. Optional live embedding/retrieval evaluation steps were skipped intentionally; no live-quality acceptance is claimed.

Existing diagnostics remain: unused test value in MemorySemanticPrecisionEvaluation.swift:343, widget CFBundleVersion1 versus parent17 and Simulator destination ambiguity. Initial AppGroup/CoreData missing-path errors were followed by explicit successful store recovery and passing tests. This is not a warning-free or device-store migration claim; no new planning/iteration source warning was observed.

## Architecture gate

The existing coordinator consumes only its current owned refinement proposal. An expected context digest is an anti-replay handle, not a transferred DTO, signed credential or accounting history. It requires finished collection, all accepted queries attempted, owned ledger/coverage and exact original collection limits. Empty proposals return the existing report without a new round or request. Changed limits/stale handles fail before mutation.

Direct validated plan append preserves old question/query identity, text and order, uses the proposal's future query order, and validates total association/query/encoded bounds before admission. Proposal construction in the coordinator also prevalidates this future append before charging/caching, so an unusable proposal cannot lock out correction. The pure proposal DTO still confers no execution authority. The coordinator reserves one additional round before accepting the extension, invalidates stale proposal/ledger/report caches and invokes the existing shared collection worker for new queries only. Every query/provider/fallback/page hop retains its existing pre-admission counter. Original run deadline, overlap guard, cancellation and operation token remain authoritative.

Collection retains earlier source text/UUID/host source IDs/first-observation provider. A duplicate requested URL adds a charged query association without refetching or replacing the old body. New source records append. Fixed ledger segmentation limits and unchanged prior bodies preserve old evidence ID/text/offset prefixes. Distinct requested redirect aliases still remain distinct sources.

On successful collection, both new ledger and coverage are rebuilt locally with previous owned host limits. Their complete generated metadata costs are reserved together before both caches are published. This is explicit per-version materialization work: changed digests and labels count even if references are stable or old labels disappear. It is not a net size delta. Prior charges remain cumulative; existing source/evidence bodies and consumed proposal/plan text are not charged again. Repeated cached getters cost zero. Failed work retains charged attempts/partial bounded collection and terminates; it does not refund, restore usable stale caches or resume implicitly.

## Verification gate

21 new XCTest methods cover three total rounds, reordered draft targets/query ID preservation, duplicate requested URLs with first provider/body/no refetch, all nine resource deltas and pre-HTTP reservations, empty no-work, missing context/replay/changed limits, round/query/search admission denials, atomic projection metadata denial, partial provider failure/source ceilings, overlap/cancel/late page/original deadline, pre-cache plan-byte/text bounds with correction, pure append wrong-run/duplicate/association forgery, fixed projection failure with deadline precedence and old evidence prefix under inherited truncation limits. Full ordinary Simulator XCTest, eight Research suite discovery guards and one generated-store migration are required before acceptance. Optional live API/provider/retrieval evaluation remains disabled. Build workflow triggers were inspected before the task push; IPA automation only matches main and is unchanged.

## Acceptance limits

- Fixtures establish orchestration and accounting, not live provider/model quality, factual support or a completeness verdict. Retrieval gaps remain availability diagnostics.
- Iteration consumes a host-supplied offline proposal; no model refinement adapter, autonomous quality selection or report synthesis is added.
- No Chat/UI, Memory/Profile, store/resume/background, IPA/main merge or production deployment. ResearchRun checkpoint remains v3.
- Existing DNS IP-pinning/late-timer and post-download byte ceiling limitations remain. Retained collection/ledger caps do not bound transient download, parsing or heap allocation; cooperative cancellation cannot forcibly terminate an uncooperative adapter.

Actual per-step logs are retained in ignored .local/ci-logs-37208933293. Final documentation handoff does not claim a separate execution on its documentation commit; source and workflow remain identical to the tested source.
