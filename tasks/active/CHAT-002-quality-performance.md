# CHAT-002 — routing, prior-tool relevance, streaming count, Markdown quotes

2026-10-18 user request: fix all four issues; preserve native tools and general Memory; test/report, no IPA.

- Branch/worktree: codex/chat-quality-performance / D:/daifuku/.worktrees/chat-quality-performance.
- Parent bb102e9 (verified math/client stack); other worktrees remain untouched.
- Task edits require explicit edit-task wording or an edit action plus a task/reminder/alarm object; bare 改成 no longer selects edit_scheduled_task.
- Chat passes current/previous user text to request-local prior-tool admission. Bounded recent candidate scan then conservative lexical relevance; generic exam labels alone do not admit results. Explicit prior-search/source references, deictic followups and prior task action audits remain possible. No persisted record deletion, reclassification, Memory retrieval/ranking changes or new LLM call.
- AgentRunner uses separate incremental grapheme counters per reasoning/content stream, retaining the final cluster for boundary merges. Same character budget and full reasoning re-entry. Unbounded pathological single combining clusters can still incur repeated boundary work; Chinese/ordinary chunk scaling is the targeted optimization, not a universal constant-time Unicode claim.
- Markdown uses the bundled Marked renderer with raw HTML tokens escaped individually, preserving blockquote syntax. Restricts links before and after MathJax, including SVG xlink href. No new dependencies, raw HTML execution, or remote renderer resources.
- Added fixtures for route positives/negatives; current/foreign conversation isolation; exclusion and old audit survival; unrelated vs older relevant sources; Unicode exactness/budget/re-entry; measured Chinese benchmark; real WKWebView bundled quote/LaTeX/table/code/XSS/link rendering.
- Local bundled Marked/Node check passed quote + escaped script. Actual Xcode/XCTest pending. Use existing test-only ios-memory-validation workflow, research_contract_validation=true, no live API/IPA.
