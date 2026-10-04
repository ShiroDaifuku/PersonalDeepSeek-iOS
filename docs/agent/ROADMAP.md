# Multi-stage Deep Search roadmap

Each increment uses a dedicated branch/worktree, independent review and tests before integration. No automatic packaging or production deployment.

1. DS-001 Foundation: immutable identity, validated state transitions, cumulative budgets, cancellation/failure, validated versioned checkpoints and offline tests. No Chat behavior change.
2. DS-002 Planning/multiple queries: DS-002A contracts and DS-002B shared model adapter accepted with full Simulator regression and generated-store migration. Checkpoint v2, cumulative output/attempt reservations, explicit output cap, one HTTP attempt and strict bounded shared transport are verified with fixtures. See tasks/completed/DS-002-research-planning.md. Live quality remains unverified and Chat remains single-pass.
3. DS-003 shared collection/evidence: DS-003A collection and DS-003B bounded ledger accepted. Source/query/question identity, first-observation provenance, Unicode offsets/truncation, full expected-context decoding and cumulative novel metadata reservations have offline Simulator evidence. Next: DS-003C coverage/gap contract (tasks/active/DS-003C-coverage-gaps.md), distinguishing retrieval associations from factual support before model refinement/contradiction checks. See tasks/active/DS-003-shared-collection-evidence.md. DS-003 remains partially complete.
4. Claims/report: claim-evidence-citation validation, explicit gaps, bounded structured synthesis through shared API/SSE.
5. Persistent lifecycle: separate research store, additive migration design/tests, checkpoint/relaunch/resume and bounded failure recovery without resetting budgets.
6. Chat/evaluation: progress and cancel/resume UX, final-answer eligibility, images/context regression, deterministic E2E, live provider evaluation and device checks.

Background research needs separate iOS feasibility review; Live Activity is status display, not execution guarantee. Register evaluator and fetch-security follow-ups separately from DS-001.
