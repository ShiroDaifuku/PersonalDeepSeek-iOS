# DS-003B bounded evidence ledger (planned)

- Dependency: accepted DS-003A accounted collection; start from updated feature/tool-research-integration in a dedicated branch/worktree.
- Goal: define bounded untrusted evidence entries and source/query/subquestion associations for later coverage/gap evaluation.
- Status: planned; no ledger implementation, live evaluation, final-report or Chat acceptance claimed.
- Architecture gate: define run/conversation binding, stable evidence/source identity, fetched-page versus search-snippet provenance, text segmentation/truncation and byte/character/count limits. Different redirect aliases and repeated provider/query observations need explicit provenance rules; do not infer all associations share the first provider.
- Validation: reject empty/oversized/dangling/duplicate/cross-run references and future schema; retain host-owned IDs/limits; decoded/transferred evidence is untrusted and requires expected-context validation. Serialization is not authenticated history or durable storage.
- Accounting gate: reuse existing retained collection charges without silently refunding/resetting or double-charging copied text. Reserve any new retained evidence/metadata work explicitly; review checkpoint compatibility before resource changes. Sole ResearchRun owner and original deadline remain authoritative.
- Split: offline ledger contracts/fixtures first; coverage/contradiction/gaps and model-driven refinement follow separate reviewed increments. No source validity, factual truth or semantic injection immunity is inferred from structurally valid evidence.
- Tests: exact binding/provenance/ID stability, duplicate/redirect alias policy, bounded segmentation/metadata, invalid references/corrupt decoding, unchanged collection accounting and terminal monotonicity; full ordinary regression/migration as applicable.
- Forbidden: Memory/Profile mutation, second search/runtime/parser, implicit paid requests, production prompts/Chat/UI, persisted research store/resume/background, IPA/main merge/deploy.
