# MATH-001 — Mathematics I, Steps 1–2

User request 2026-10-18: implement local math learning foundation and photo/stepwise teaching, limited to postgraduate entrance Mathematics I. Ordinary chat and Memory unchanged. No IPA authorized for this feature.

- Worktree D:/daifuku/.worktrees/math-tutor-foundation; branch codex/math-tutor-foundation; parent client-media-web-settings/ac634ad.
- Entry: chat composer + menu -> separate Mathematics teaching sheet. ChatView.send, MessagePrefix, APIClient, AgentRunner, Memory and primary app ModelContainer remain unchanged.
- Local-only independent MathStudy/math.store with CloudKit disabled. Never delete/recreate a corrupt store. Lazy open isolates failures from chat startup. ModelActor + snapshots; original normalized JPEG in private MathStudy/Photos directory.
- Entities: MathProblem, MathAttempt, MathKnowledgePoint, MathLearningEvidence. Last entity reserves future evidence storage only. No extraction, ranking, mastery, cross-problem recall, or general profile mutation. Coarse syllabus IDs are navigation taxonomy, not a verified annual official syllabus.
- Photo/text -> target a single question -> editable transcription -> explicit verification -> save immutable problem -> hint/one-step/full answer/check work. Failed/cancelled outputs marked incomplete, excluded from future context. Only selected problem's <=6 successful turns and <=12000 history characters included. Explicit user actions only call existing Flash API with no tools and thinking disabled; no hidden chain displayed. Hint restraint is an LLM instruction, not a mathematical guarantee.
- Tests: schema CRUD/reload/cascade including evidence fixture, photo ownership/deletion, invalid input, independent old chat persistence, concurrency, prompt boundaries, opt-in user actions, recognition confirmation, cancellation/empty/truncated responses, and dark/dynamic-type host mount.
- Pending: actual macOS build/test. Windows cannot run Swift/Xcode. Reuse test-only ios-memory-validation workflow; never invoke build-ios.yml. Phone camera/UI and real mathematical correctness remain separate acceptance.
