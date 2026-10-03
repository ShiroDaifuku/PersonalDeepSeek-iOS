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
- Status: implementation and independent review in progress.
- Result: pending executable verification.
- Follow-ups: planner/multi-query, durable store/resume, Chat integration.
