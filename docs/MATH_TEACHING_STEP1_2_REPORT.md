# Mathematics I — Step 1 / Step 2 implementation

Date: 2026-10-18, Asia/Hong_Kong. Branch: `codex/math-tutor-foundation`.
Parent: `ac634ad7972e0071d7e235477a406c5571e4813c` (verified client image/web/settings fix).
Worktree: `D:/daifuku/.worktrees/math-tutor-foundation`.

## Scope and user workflow

Chat composer **+ → 数学教学 · 考研数学一** opens a separate screen. It does not turn the current ordinary conversation into a tutoring conversation.

1. Select 高等数学 / 线性代数 / 概率论与数理统计, and optionally a coarse knowledge-point category.
2. Type a question directly, or select/take one photo. Specify one target question when the photo contains multiple questions.
3. Explicitly request transcription. The prompt forbids solving, preserves conditions, and marks illegible symbols as `【不清晰】` rather than guessing.
4. Edit the transcription. Formula preview uses the existing LaTeX/Markdown renderer. The user must check the verification toggle before saving.
5. Choose 一点提示 / 下一步引导 / 完整解答 / 检查我的步骤. Checking work requires nonblank user steps. The send button dismisses the keyboard.
6. Stop generation if needed. Partial/failed results are labeled incomplete and are not fed into later successful-turn context.
7. Reopen the math archive, inspect the original photo and teaching records, share responses, or explicitly confirm deletion of a question and its records.

The 23 coarse topic IDs are navigation taxonomy, not a verified exhaustive syllabus for any particular examination year. Fine-grained error taxonomy and prerequisite relationships are deferred.

## Storage, boundaries, and data protection

Lazy-open independent `Application Support/MathStudy/math.store`, CloudKit disabled. No modifications to the primary app schema, schema migration plan, Conversation/ChatMessage entities, or primary store location. Failure to open the math store displays an error in the math screen; it never deletes/recreates the store or blocks ordinary app startup.

`MathLearningStore` uses `@ModelActor`, explicit saves/rollback and plain Codable/Sendable snapshots. No SwiftData models are passed into teaching tasks. All model scope IDs are `local-default`, independent of `opaqueUserID`.

Normalized images use the existing upright SDR JPEG conversion. Original normalized JPEGs are stored as UUID-owned private files, not an expiring file_id. Reads validate the expected filename. Failed DB creation attempts clean up their newly written photo. Deletes commit the database first; a subsequent file cleanup error is explicitly reported and does not leave a nonexistent question displayed as live. A crash between photo write and DB save can leave an orphan private image; no broad cleanup or destructive recovery is implemented.

### Actual entities

- `MathProblem`: `id: UUID` unique; `scopeID: String`; `statement: String`; `subjectRawValue: String`; `topicID: String?`; `photoFilename: String?`; `confirmedAt: Date`; `createdAt: Date`; `attempts: [MathAttempt]` cascade/inverse `problem`; `evidence: [MathLearningEvidence]` cascade/inverse `problem`.
- `MathAttempt`: `id: UUID` unique; `scopeID: String`; `modeRawValue: String`; `userWork: String`; `response: String`; `statusRawValue: String`; `createdAt: Date`; `problem: MathProblem?`. Append is idempotent by attempt ID, but rejects a different payload using an existing ID.
- `MathKnowledgePoint`: `id: String` unique stable topic ID; `scopeID: String`; `subjectRawValue: String`; `title: String`; `createdAt: Date`. Idempotently seeded with coarse categories; no mastery score.
- `MathLearningEvidence`: `id: UUID` unique; `scopeID: String`; `topicID: String`; `sourceAttemptID: UUID`; `note: String`; `createdAt: Date`; `problem: MathProblem?`. Reserved schema only. Production has no evidence inference writer. Tests insert a fixture to exercise actual cascade deletion.

`MathProblemSnapshot` and `MathAttemptSnapshot` are Codable + Sendable + Equatable; the former includes only its own ordered attempts. There is no relationship to ordinary Conversation or Memory models.

## AI request behavior

`MathTutorPrompt` builds fresh math-only messages. `MathTutorClient` delegates to the unchanged `APIClient`, using the existing chat Keychain key, `deepseek-flash`, thinking disabled, no tools, output max 4096 tokens.

Only an explicit transcription or teaching button triggers a request. Save/list/delete/open do not call the model. There is no automatic extraction, mastery update, image backfill, cross-problem retrieval, or general Memory/Profile read/write.

Teaching uses the user-confirmed text, not an assumption that OCR was perfect. Images/steps are untrusted task data. Only the selected problem's latest up to six completed turns, bounded to 12000 history characters, enter the request. Failed/cancelled turns are excluded. Statement <=12000 characters; work <=8000; collected output <=32000 (transcription <=12000). UI updates are coalesced to approximately 100 ms rather than rendering every token.

Hint/next-step restraint and mathematical correctness remain model behaviors, not guarantees. A full-answer request is explicit. This version does not measure mastery just because the user requested or read an answer. Geometry conditions must be supplied in the confirmed text; this is not an independent geometric diagram solver.

## Ordinary chat / Memory regression boundary

`ChatView.swift` changes only: one presentation state, one sheet and one menu button. `ChatView.send()`, `MessagePrefix.stable()`, `APIClient`, `AgentRunner`, tools/SSE, primary models/container, Memory/Profile implementation, backend and Research state machine are unchanged.

The existing ordinary chat initialization and Memory read/write behavior remain in place. Mathematical teaching is deliberately not persisted as ordinary ChatMessages, so it cannot accidentally enter the visible-completed-turn Memory extraction hook.

## Validation history

Windows has no Swift/Xcode runtime. Actual validation uses the existing macOS Simulator workflow (`ios-memory-validation.yml`), never the IPA workflow. One optional math smoke input was added to that test-only workflow. Real smoke uses only a UIKit-generated public derivative problem, the existing CI secret, and the production math prompt/client. It checks transport/nonempty output; its readable transcription/hint/solution evidence is for human review, not a general math accuracy classifier.

- Run 39098641949 / source `17e7f7b`: actual compile failure. `catch`'s implicit local `error` shadowed the view model's mutable `error` property in two methods. Fixed with `self.error`; failure history retained.
- Run 39098843656 / source `194e267`: same compile failure before that fix, retained separately.
- Run 39098921690 / source `e7d8365`: SwiftData macro initializer compile error: reading `confirmedAt` before every stored property was initialized. Fixed by a local `now` value assigned independently to both timestamps.
- Subsequent verification results: pending; update this section from real logs, not assumptions.

Fourteen MathLearningTests are defined (13 ordinary + 1 opt-in real API). Coverage includes CRUD, restart/reload, provenance fixture cascade, original-photo ownership, invalid fields/paths/images, idempotence, 30-task concurrency, independently reopened ordinary chat/Memory fixtures, prompt bounds/modes, explicit-only requests, human confirmation, stop/empty/truncated output handling and dark/accessibility-size host mounting.

The host mount test is not a full XCUITest nor a real camera/touch/VoiceOver acceptance. No real existing user database or private photo is used in tests. Model hint discipline and broad curriculum correctness need a representative reviewed Mathematics I exercise set later.

## Deferred / not implemented

No automatic error analysis, evidence extraction, mastery algorithm, cross-question associations, review scheduling, knowledge graph, cloud sync, old-chat backfill or general Memory/Profile updates. Saved problem text is immutable once teaching records exist; corrections currently create a new problem. Drafts that have not been confirmed are not restart-persistent. One photo / one confirmed question per problem.

No IPA generated for this feature, no main/canonical merge, no production deployment, no new dependencies.
