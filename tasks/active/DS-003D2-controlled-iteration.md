# DS-003D2 controlled iterative collection (planned)

- Dependency: accepted DS-003D1 offline refinement contract; dedicated branch/worktree from updated feature/tool-research-integration.
- Goal: consume an owned proposal in a bounded additional collection round using the existing coordinator and shared LocalResearchService.
- Status: planned; no additional requests, iterative lifecycle, model refinement or Chat acceptance claimed.
- Architecture gate: extend the accepted plan while preserving question/query/source identity, global dedup and cumulative query/HTTP/metadata accounting. Define refreshed ledger/report generation and cache invalidation; prior charged text must not be silently refunded or charged again.
- Lifecycle: reserve rounds and logical queries before work, provider/fallback requests and page hops before HTTP; preserve original deadline, overlap exclusion and late-callback rejection. Decoded proposals cannot claim prior execution or adopt history.
- Split: deterministic fixture coordination first; optional shared model refinement adapter and live quality evaluation are separate gates. Invalid proposals or exhausted resources must never initiate provider calls.
- Tests: multiple bounded rounds, shared sources across queries, no repeated planned/attempted work, identity stability, updated coverage, exact charges, admission/failure/cancel/deadline and full Simulator regression/migration.
- Forbidden: second run actor/search/parser, implicit model calls/unbounded retry, Memory/Profile or persistence/background/Chat changes, IPA/main merge/deploy.
