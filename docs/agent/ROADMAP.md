# Multi-stage Deep Search roadmap

Each increment uses a dedicated branch/worktree, independent review and tests before integration. No automatic packaging or production deployment.

1. DS-001 Foundation: immutable identity, validated state transitions, cumulative budgets, cancellation/failure, validated versioned checkpoints and offline tests. No Chat behavior change.
2. Planning/multiple queries: bounded question decomposition, typed planner output and query IDs, injectable planner/gather interfaces; reuse LocalResearchService.
3. Evidence/gaps: stable source/evidence IDs, URL deduplication, coverage/contradiction checks, bounded refinement; account for all work against run budget.
4. Claims/report: claim-evidence-citation validation, explicit gaps, bounded structured synthesis through shared API/SSE.
5. Persistent lifecycle: separate research store, additive migration design/tests, checkpoint/relaunch/resume and bounded failure recovery without resetting budgets.
6. Chat/evaluation: progress and cancel/resume UX, final-answer eligibility, images/context regression, deterministic E2E, live provider evaluation and device checks.

Background research needs separate iOS feasibility review; Live Activity is status display, not execution guarantee. Register evaluator and fetch-security follow-ups separately from DS-001.
