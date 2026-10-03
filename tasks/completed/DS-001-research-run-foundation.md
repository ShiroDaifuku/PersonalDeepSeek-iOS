# DS-001 ResearchRun Foundation

- Goal: testable lifecycle and cumulative budgets before planner/network integration.
- Dependencies/context: canonical 88f6776; ADR-001/002/003.
- Branch: codex/deepsearch-run-foundation.
- Worktree: D:/daifuku/.worktrees/ds-001.
- Owner: implementation agent; Lead owns control docs/integration.
- Reviewer: independent reviewer agent.
- Allowed code: new ios/Core/ResearchRun*.swift and ios/Tests/ResearchRunTests.swift.
- Forbidden: Chat/actual planner/network integration, ledgers, SwiftData/store migration, storage I/O/resume execution, backend/Cloudflare, prompts, dependencies, IPA/deploy.
- Acceptance: immutable identity/conversation/query; legal transitions; terminal monotonicity; cancel/fail never imply completion; nonnegative bounded overflow-safe counters; failed mutation atomic; injected clock; elapsed budget survives checkpoint; validated versioned roundtrip and corrupt/future rejection.
- Tests: deterministic XCTest for transitions, terminal rules, all ceilings, invalid policies, overflow, time and corrupt checkpoints. iOS test-only CI if available; no live API evaluation required.
- Status: completed; independent review accepted and actual Simulator verification passed. Approved for fast-forward integration into the canonical development branch.
- Result: implementation da9c35c; test-only inherited run() name collision repaired in ff0e361. Initial CI 37118022406 remains failed. Final CI 37119696346 passed: ResearchRun 10/10, ordinary 240 total / 16 skipped / zero failures, selected migration 1/1, provider/retrieval evaluations 1/1 each. All 64 phase pairs covered. No Chat/API/network/schema/Memory behavior changes, IPA, release or production deploy.
- Evidence: docs/evaluations/ds-001/VALIDATION.md and summary.json. Later handoff commit changes only docs/evidence, not tested Core/Tests.
- Follow-ups: planner/multi-query, durable store/resume, Chat integration.
