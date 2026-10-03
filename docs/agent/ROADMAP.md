# Multi-stage Deep Search roadmap

Each increment uses a dedicated branch/worktree, independent review and tests before integration. No automatic packaging or production deployment.

1. DS-001 Foundation: immutable identity, validated state transitions, cumulative budgets, cancellation/failure, validated versioned checkpoints and offline tests. No Chat behavior change.
2. DS-002 Planning/multiple queries: split DS-002A pure plan contracts/fixture coordination from DS-002B shared APIClient model adapter. First validate typed drafts, bounded stable host-assigned IDs and query deduplication; then define model output/token/attempt/deadline accounting and version compatibility before live calls. Reuse LocalResearchService. See tasks/active/DS-002-research-planning.md; implementation starts only after DS-001 validation/integration.
3. Evidence/gaps: stable source/evidence IDs, URL deduplication, coverage/contradiction checks, bounded refinement; account for all work against run budget.
4. Claims/report: claim-evidence-citation validation, explicit gaps, bounded structured synthesis through shared API/SSE.
5. Persistent lifecycle: separate research store, additive migration design/tests, checkpoint/relaunch/resume and bounded failure recovery without resetting budgets.
6. Chat/evaluation: progress and cancel/resume UX, final-answer eligibility, images/context regression, deterministic E2E, live provider evaluation and device checks.

Background research needs separate iOS feasibility review; Live Activity is status display, not execution guarantee. Register evaluator and fetch-security follow-ups separately from DS-001.
