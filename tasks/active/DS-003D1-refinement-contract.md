# DS-003D1 offline refinement proposal contract

- Goal: validate bounded untrusted additional-query drafts into host-owned proposals from explicit retrieval diagnostics; proposals are not executed plans or authorization to call a provider.
- Dependency/baseline: accepted DS-003C, 49cbda114945a55f106565b7a9a58e81e186bccf.
- Branch/worktree: codex/deepsearch-refinement-contract / D:/daifuku/.worktrees/ds-003d1.
- Status: implementation; architecture gate accepted 2026-10-04, Simulator verification pending.
- Owners: ds003d_implementer Core/Tests; ds003d_reviewer independent source review; ds003d_architecture architecture/test/log audit; Lead docs/workflow/CI/integration.
- Contract: expected host plan/run/query/planning limits binding, complete rebuilt ledger/coverage equality, canonical attempted IDs, stable immutable run context (identity/query/createdAt/budget), bounded future query IDs and existing question/gap references. Reject normalized duplicate or already planned queries, including unattempted ones. Use shared planning normalization.
- Serialization: private host construction, validated versioned Codable and bounded Data wrapper requiring the original draft and full expected context. Digests bind identity, not authenticated history/accounting. Canonical budget representation uses ordered resource rows, not enum-keyed dictionary serialization.
- Accounting/lifecycle: existing coordinator requires owned ledger/report and evaluating finished collection; precharge only new proposal text/metadata, cache identical request/limits once. Correctable draft/context or cache-conflict errors before reservation do not mutate the run; budget, deadline and cancellation retain terminal behavior. No rounds/queries/planner/HTTP debit, no implicit plan/attempted/source/report mutations or execution.
- Tests: gap/reference scope, Unicode global dedup, raw bytes/grapheme/character/count limits, prior planned unattempted query rejection, future schema/corrupt graph, forged generic report/ledger, exact run/budget/createdAt/context/attempted identity, metadata delta/cache/conflict/correction, original deadline/cancel/budget and full regression/migration.
- Forbidden: model/search requests, new run resource/checkpoint version, Memory/Profile, Chat/UI, storage/resume/background, IPA/main merge/deploy.
- Follow-up: DS-003D2 validates and consumes owned proposals through reviewed bounded plan extension/iteration without inventing or resetting accounting history.
