# DS-003C bounded coverage and gap contract (planned)

- Dependency: accepted DS-003B evidence ledger; start from updated feature/tool-research-integration in a dedicated branch/worktree.
- Goal: deterministic bounded per-subquestion evidence coverage and explicit collection gaps, as input to later reviewed refinement and synthesis.
- Status: planned; no factual support, contradiction detector, model refinement or Chat acceptance claimed.
- Architecture gate: consume the expected-context-validated ledger and accepted plan; distinguish available page/snippet entries, absent evidence and ledger truncation. Query association is retrieval provenance, not proof of relevance, factual truth or a supported claim.
- Validation: host-owned stable question/evidence references, exact run/conversation/plan binding, bounded report and validating transferred-input contracts. Empty results must remain explicit gaps; do not silently label a question answered because a query returned a source.
- Accounting gate: existing coordinator/run remains sole owner; reuse already charged content, reserve new retained report metadata explicitly, preserve original deadline and cumulative usage. No implicit requests or budget resets.
- Tests: shared-query/many-to-many associations, empty/metadata-only/partially truncated ledgers, snippet versus page distinctions, deterministic identities, corrupt or cross-context references, exact budget delta and terminal behavior; full Simulator regression and migration.
- Follow-up: separately design bounded query refinement and factual claim/evidence/citation evaluation after this offline contract is reviewed.
- Forbidden: Memory/Profile mutation, new search/runtime/parser, production prompts/Chat/UI, persistence/resume/background, live paid requests, IPA/main merge/deploy.
