# Current engineering state

Updated: 2026-10-03 (Asia/Hong_Kong).

## Canonical baseline

Branch: feature/tool-research-integration. Takeover HEAD: 88f6776a4ce6da34c7ff50f464840d1d69cfa5c1. Final evaluated source: 77326fd93c5109d1d05a1f8212a6625f3a2aa7ba. Frozen production source before Deep Search development: cb87131e91d999322d210215b767e8865c83888e. Takeover HEAD adds reports/evidence only; the canonical worktree was clean.

D:/daifuku is a historical branch checkout with user-owned untracked files; preserve it. New work has its own branch/worktree.

## Accepted capabilities

Ordinary AgentRunner native tools, bounded multi-round protocol, reasoning re-entry, audit persistence and future-turn tool history exist. Explicit Chat Research currently gathers once and synthesizes once. LocalResearchService is shared low-level search/fetch. Memory/Profile is isolated from raw research/tool evidence.

The prior integration report records 230 ordinary XCTest tests (16 skipped, zero failures), two migration tests, one real Bing RSS Research E2E, and seven Cloudflare tests. This is historical component/simulator evidence, not device UI or Brave validation. The takeover audit did not rerun these tests or independently query remote CI.

## Completed increment

DS-001 ResearchRun Foundation accepted: independent state, cumulative budgets, cancellation/failure, validated versioned checkpoints and ten deterministic tests. No connection to Chat, network, API, Memory, tools or SwiftData. See tasks/completed/DS-001-research-run-foundation.md.

Source ff0e3617268d27072cbe779ba2141137a3906e53 passed actual Simulator CI run 37119696346: build, 240 ordinary tests (16 skipped, zero failures), ResearchRun 10/10, selected generated-store migration 1/1 and local provider/retrieval evaluations 1/1 each. Independent review accepted source and the test-only repair. First run 37118022406 failed compilation due to a fixture helper named run shadowed by XCTestCase.run; it remains failed and is documented in docs/evaluations/ds-001/VALIDATION.md. Assertions and production model were unchanged by repair.

DS-002A accepted: bounded untrusted draft -> host-owned plan, global query deduplication/associations, injected planner/fake query coordinator, cumulative reservations and cooperative cancellation/deadlines. Independent review accepted the implementation and deterministic DNS fixture repair. Source 43dd89a34bc4f62f03f49a5c65e1c88bfe030ba2 passed Simulator run 37123424473: 254 ordinary tests (16 skipped, zero failures), Planning 14/14, Run 10/10 and selected generated-store migration 1/1. First run 37122839222 failed one unchanged timing-sensitive DNS test; history and production deadline limitation remain in docs/evaluations/ds-002a/VALIDATION.md. See tasks/completed/DS-002A-planning-contract.md. DS-002B model adapter output/token/attempt/deadline accounting remains planned. Current Chat Research remains single-pass.

## Known follow-ups

- Planner, multi-query search, gap analysis, ledgers, synthesis mapping, durable store and resume execution remain future work.
- Historical Memory five-trial evaluator computes each pass but does not assert every pass; saved evidence records five successes. Correct separately without altering production semantics.
- Local DNS precheck does not pin connection IP; page-byte ceiling applies after full download. These are static limitations, not reproduced exploits.
- DNS resolver uses first-callback-wins; a delayed timer may accept lookup success after its nominal deadline. Define monotonic deadline semantics and reject late success in a separate production task. DS-002A repairs only the scheduling-sensitive DNS test fixtures, not this production limitation.
- Cloudflare scheduled-task fetch has weaker validation than local Research, but is not Chat's interactive Research path.
- Legacy ResearchView is not wired into RootView.

No IPA, main merge, release, production deploy or production migration is authorized.
