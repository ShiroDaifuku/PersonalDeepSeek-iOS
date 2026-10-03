# Current engineering state

Updated: 2026-10-03 (Asia/Hong_Kong).

## Canonical baseline

Branch: feature/tool-research-integration. Takeover HEAD: 88f6776a4ce6da34c7ff50f464840d1d69cfa5c1. Final evaluated source: 77326fd93c5109d1d05a1f8212a6625f3a2aa7ba. Frozen production source before Deep Search development: cb87131e91d999322d210215b767e8865c83888e. Takeover HEAD adds reports/evidence only; the canonical worktree was clean.

D:/daifuku is a historical branch checkout with user-owned untracked files; preserve it. New work has its own branch/worktree.

## Accepted capabilities

Ordinary AgentRunner native tools, bounded multi-round protocol, reasoning re-entry, audit persistence and future-turn tool history exist. Explicit Chat Research currently gathers once and synthesizes once. LocalResearchService is shared low-level search/fetch. Memory/Profile is isolated from raw research/tool evidence.

The prior integration report records 230 ordinary XCTest tests (16 skipped, zero failures), two migration tests, one real Bing RSS Research E2E, and seven Cloudflare tests. This is historical component/simulator evidence, not device UI or Brave validation. The takeover audit did not rerun these tests or independently query remote CI.

## Active increment

DS-001 ResearchRun Foundation: independent state, cumulative budgets, cancellation/failure, versioned validated checkpoints and deterministic tests. No connection to Chat, network, API, Memory, tools or SwiftData. See tasks/active/DS-001-research-run-foundation.md.

## Known follow-ups

- Planner, multi-query search, gap analysis, ledgers, synthesis mapping, durable store and resume execution remain future work.
- Historical Memory five-trial evaluator computes each pass but does not assert every pass; saved evidence records five successes. Correct separately without altering production semantics.
- Local DNS precheck does not pin connection IP; page-byte ceiling applies after full download. These are static limitations, not reproduced exploits.
- Cloudflare scheduled-task fetch has weaker validation than local Research, but is not Chat's interactive Research path.
- Legacy ResearchView is not wired into RootView.

No IPA, main merge, release, production deploy or production migration is authorized.
