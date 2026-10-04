# DS-003D3 shared model refinement adapter (planned)

- Dependency: accepted DS-003D2 controlled iterative collection; dedicated branch/worktree from canonical feature/tool-research-integration.
- Goal: produce bounded gap-target refinement drafts through existing APIClient/SSE transport, then use the host proposal/iteration contracts.
- Status: planned; DS-003D2 establishes deterministic controlled execution only. DS-003 remains partially complete until this separately reviewed adapter gate.
- Architecture gate: explicit bounded input projection of current plan/retrieval diagnostics; untrusted evidence cannot become instructions or accounting authority. No second runtime/parser/search stack. Model output is an untrusted draft, validated by the existing host contracts.
- Accounting: reserve planningAttempts and capped planningTokens before one shared model HTTP attempt. A model suggestion consumes no execution round; the existing iterate method separately reserves a round when actual work is admitted. Preserve the original run deadline, overlap/cancellation guard and cumulative usage without refunds or retries.
- Tests: injected shared transport/SSE fixtures, empty/no-work draft, novelty and context binding, input/output/schema bounds, explicit attempt/output reservation, failure/cancel/deadline and full Simulator regression/migration.
- Live provider/model quality and autonomous stopping policy require separate evidence; fixture correctness is not factual sufficiency. Claims/evidence/citation and report synthesis remain DS-004.
- Forbidden: paid new service, implicit model/search loop, Memory/Profile or Chat/UI mutation, persistence/resume/background, IPA/main merge/deploy.
