# Integration Step 2.1 — Final E2E Acceptance Report

Date: 2026-10-03. Status: **PASS — final Research-only CI 37114253350 succeeded**.

## A. Production Source Freeze

**production source unchanged from cb87131** (`cb87131e91d999322d210215b767e8865c83888e`).

Worktree: `D:\daifuku-worktrees\tool-research-integration`; branch: `feature/tool-research-integration`.
Final tested source: `77326fd93c5109d1d05a1f8212a6625f3a2aa7ba`; subsequent commit is reports/evidence only.

No changes to `ios/Core`, `ios/Features`, App/Widget production source, Cloudflare or Node backend. Only tests, opt-in workflows and reports were added/changed. AgentRunner, APIClient, SSEParser, Research, Memory extraction/backfill/profile and production prompts remained frozen.

## B. Explicit Deep Research E2E

The test uses actual production components, not mocked search or fabricated research evidence:

```text
AssistantIntentRouter.preferredTool / directCall
  -> LocalResearchService.gatherWithMetadata (real provider + page fetch)
  -> ChatRequestAssembler.researchMessages
     -> ResearchContextBudgeter.prepare
  -> AgentRunner(enabledTools: [])
     -> APIClient.streamRound -> real DeepSeek SSE synthesis
  -> final assistant ChatMessage saved in fixture SwiftData container
```

This is a component E2E harness, **not SwiftUI UI automation or an iPhone run**. The same methods called by `ChatView.send()` are exercised; the harness does not call that private SwiftUI function.

Public query: `DeepSeek API Platform auto-caching 官方平台的自动缓存与缓存命中折扣`.
It was selected under the explicit allowance to choose a searchable public query on the test day. Bing RSS did not recall the specialized accounting-field docs; it did return the official platform page. The question concerns automatic caching and cache-hit discounts, not credentials/private data.

Prior complete run 37113103474, source 166c869: route count 1, 6 sources, 4 successful page fetches, 2 snippet-only fallbacks; real synthesis finished with `stop`, nonempty final answer was persisted. Its new fact verifier failed on the official directory-URL filter. Raw result is preserved, not reclassified as a green CI run.

Final corrected-verifier E2E result: **PASS**, run 37114253350. Route count 1; 6 real sources; 6 successful text-page fetches, 0 snippet-only fallbacks; budget applied with truncation; one real DeepSeek synthesis, `finish_reason=stop`; nonempty final assistant persisted. HTTP/text fetch success is not a claim that every page is substantive: the download page has only 12 text characters. The official platform page has 1152 characters and actually contains the verified public caching statement.

Final answer cites **[2]**, the current official platform source. `actualSourceFactVerified=true`; `verifiedFactSourceURL=https://www.deepseek.com/en/platform/`. No native `web_search` invocation is claimed by the answer. Verification is deliberately bounded to this public fact and valid citations, not a full factual/linguistic audit of every generated price discussion; the sample's Chinese discount wording is not fully rigorous.

## C. Provider

Actually used: **Bing RSS fallback**, reported by production `ResearchGatherResult.providerUsed`.
No Brave key was injected and **Brave is not validated**.

First run 37092781022 failed its initial Bing search request after approximately 20 seconds with `NSURLError -1001`. Later real native searches in that same run succeeded. This failure remains in `initial-research-timeout.json`; it is not rewritten as PASS.

A separate recorded public no-tool network preflight was added to the diagnostic harness. It is not part of production Research and is counted separately. In run 37113103474 it returned `4` in 0.876 seconds; final run returned `4` in 1.851 seconds. It does not cache or mock the search response. The timeout's precise network root cause has not been proven on a physical device.

## D. Research Request

Final passing E2E captured actual synthesis request:

```text
roles: system, system, system, system, system, system, user
order: base / synthetic profile / researchSafe prior history /
       current Research evidence / synthetic atomic memory / clock / user
history: 0 characters
evidence: 18835 / 26000 characters
total text: 20475 / 48000-character application ceiling
serialized request: 22227 bytes / 48 MiB transport ceiling
sources: 6
truncation: true (production budget actively applied)
synthesis completions: 1
```

No raw webpage body, authorization header or key is included in the report. Final result and public source titles/URLs are recorded. Text character budgets are not claimed to be exact model token counts.

Actual synthesis usage: 5317 prompt tokens, 939 completion tokens, 341 reasoning tokens; cache hit 128, miss 5189. One synthesis completion: 5175.48 ms, TTFT 1089.996 ms. These are synthesis metrics, not total search/fetch/UI elapsed time.

## E. Evidence Deduplication

Final actual synthesis: current Research evidence occurrences **1**; current Research `role=tool` duplicates **0**; native executor calls **0**; tools offered to synthesis **none**. New structural image/coexistence test also passed.

## F. Routing

Production router assertions passed:

```text
ordinary latest / explicit web lookup -> web_search
explicit 深度研究                   -> start_deep_search -> Research path
```

Explicit Research invokes the production direct call once. Its synthesis runner receives `enabledTools: []`. Ordinary native smoke uses registered `web_search`, not the Research assembly path. Native smoke forces the initial tool for protocol exercise; it is not proof that every possible unforced natural-language query will make a model choose the desired tool.

## G. Native Smoke

Real API smoke in run 37092781022: **4/4 PASS; protocol failures 0**.

| Case | Completions | Physical tool calls | Boundary / result |
|---|---:|---:|---|
| no-tool | 1 | 0 | Real DeepSeek; answer 4 |
| native web_search | 2 | 2 | Real public search; both succeeded; final answer |
| multi-round refinement | 3 | 3 | Controlled public park fixture; live model decisions/transport |
| thinking re-entry | 3 | 2 | Real public search; both succeeded; final answer |

Thinking case: **thinkingReentryObserved = true**; nonempty assistant `reasoning_content` was re-entered alongside `tool_calls` and matching `role=tool` IDs. Every captured transcript passed the production validator. No synthetic secret/code was used in this smoke criterion. Refinement sources are explicitly synthetic; they are not claimed as real web results.

## H. Backfill same_fact

**No direct production backfill diff** relative to Tool Runtime 0d67fef or canonical Research c3d15f6. Checked MemoryBackfill, MemoryProcessor, MemoryExtraction, MemoryStore, MemoryModels, MemoryService, UserProfileManager and ProfileContext. No production prompt/configuration change.

Five independent real trials in run 37092781022, each with a fresh container/store/processor:

```text
user: 我的电脑是 RTX 4070 Laptop。
assistant: 明白。
seed: 用户的电脑是 RTX 4070 Laptop。
seed kind: durableFact; confirmation date: 2026-09-01 UTC
completed turn: 2024-01-01 UTC; historicalBackfill
assertion: one active seed, unchanged newer confirmation date,
           reinforcementCount >= 1
```

| Trial | Processing classification | Raw extraction action | Reinforcement count | Prompt / completion tokens | Gate |
|---|---|---|---:|---:|---|
| 1 | processed | reinforce | 1 | 1067 / 75 | PASS |
| 2 | processed | reinforce | 1 | 1073 / 81 | PASS |
| 3 | processed | reinforce | 1 | 1070 / 78 | PASS |
| 4 | processed | reinforce | 1 | 1072 / 80 | PASS |
| 5 | processed | reinforce | 1 | 1070 / 78 | PASS |

All preserved the canonical text and newer confirmation timestamp. Total usage: 5352 prompt + 392 completion = 5744 tokens. All raw decoded classifications are preserved in `same-fact-five-trials.json`.

The frozen nine-case test body remains identical to cb87131. No failed-trial-only rerun, changed fixture/assertion, Memory prompt change or later extra batch of these trials. Follow-up CI explicitly skips them.

Per the requested Case A rule: **non-reproduced stochastic evaluation failure**. Original 8/9/noop is retained; these five trials do not mathematically prove an extractor will never fluctuate.

## I. Memory/Profile Boundary

Synthetic Profile, Atomic Memory and researchSafe historical tool context coexist in the assembled request. Old numeric labels become full-width `［9］` and cannot occupy current `[n]` citation namespace.

Actual final E2E compared SwiftData snapshots before/after synthesis: **Memory unchanged; Profile unchanged**. A seeded memory and empty stored profile were preserved. The harness does not invoke an extractor or updater; this checks direct raw-evidence storage isolation, not arbitrary future extraction behavior.

Production source audit: `ChatView.send()` calls `CompletedTurnEligibility.snapshot` only after successful final-answer persistence, passing visible `displayText` and `assistant.content`. It does not pass `researchSources`, request messages, raw tool payloads or evidence into Memory. Existing Memory tests remained in the ordinary suite.

## J. Image / Cancellation

Structural image test passed: current user image occurs once in decoded wire JSON, no duplicated base64, body below production limit, Research evidence once, no current role=tool duplicate; Profile/Memory/history coexist.

Controlled synthesis cancellation passed: no final-answer event, no successful completed-turn snapshot, harness generation state cleared. Existing real-production controlled gather/DNS/search cancellation tests and AgentRunner cancellation tests also passed.

Actual `ChatView` cleanup is **source-audited, not device-UI-tested**: cancellation catch followed by `finishGeneration()` clears `isStreaming`, stream task and tool status; unsuccessful turns are ineligible for Memory. No new ResearchRun/resume state.

The first new cancellation test had an observation bug: it required a thrown CancellationError and read state before defer. Async streams can terminate normally on task cancellation. Only the new harness was corrected; run 37092365323 remains failed (2 assertion failures), not rewritten.

## K. Build / XCTest / Migration

Xcode 16.4, Swift 6, macOS-15, iOS 18.5 Simulator; actual CI, not inferred from Windows.

Final run 37114253350: **build PASS; ordinary 230 tests, 16 skipped, 0 failures; dedicated migration 2 tests, 0 failures; real Research 1/1 PASS; network preflight 1/1 PASS**. Skips are opt-in evaluation tests without live flags, not suppressed failures. XcodeGen includes the new tests and XCTest app launched on the real macOS CI Simulator.

Run 37092781022: ordinary **228 tests, 15 skipped, 0 failures**, migration **2 tests, 0 failures**. Run 37113103474: ordinary **229 tests, 16 skipped, 0 failures**, migration **2 tests, 0 failures**. Native smoke and five Memory trials were not repeated in the final Research-only run.

Old-store preservation includes MemoryStoreTests' 2 Conversations/3 Messages, unchanged system prompts/content/relationships and cascade rule; ToolExecutionTests' legacy Conversation/message preservation; generated pre-Step-3 persistent fixture's MemoryItem and MemorySource preservation. These are real generated old-schema fixtures, **not the user's device database**. No production store was deleted/recreated to bypass migration.

Cloudflare local and CI: `npm run check` PASS; `npm test` **7/7 PASS**. No deployment or package/lockfile changes.

Existing compiler/build warnings retained: unused `test` at MemorySemanticPrecisionEvaluation.swift:343; extension CFBundleVersion 1 vs containing app 17. No new Swift 6 concurrency compiler errors/warnings observed. Infrastructure also reports deprecated Node20 action runtime (checkout/upload-artifact v4 forced to Node24); existing dependency audit advisories were not fixed in this frozen phase.

## L. Previous Evaluator Limitations

Unchanged and retained:

- Native B literal `http`: source/tool execution succeeded, old evaluator demanded a literal string.
- Native I synthetic launch-code refusal: real reasoning/tool re-entry occurred; refusal is not protocol failure.
- Step 2.1 temporal classifier false negatives: historical red runs remain red.
- Historical backfill 8/9/noop remains a historical result; fresh 5/5 is separate evidence.

New harness issue retained separately: official directory-URL source filter incorrectly required `/platform/` in `URL.path`. The corrected harness matches the final path component and records normalized host/path/fact presence. **Real macOS diagnostic printed `normalizedPath /en/platform`**; final source snapshot also reports `parsedPath=/en/platform`, `officialPlatform=true`, `publicCachingFactPresent=true`. This confirms the prior source-filter false negative. Offline directory-URL regression test passed. No production prompt/API/source behavior was altered to repair it.

## M. Git / CI

No main merge, rebase, Cloudflare deploy, IPA archive/upload/release or packaging dispatch.
Feature push is safe: build-ios.yml automatic push only targets main; validation is manual opt-in.

| Run | Source | Original CI outcome / purpose |
|---|---|---|
| [37092365323](https://github.com/ShiroDaifuku/PersonalDeepSeek-iOS/actions/runs/37092365323) | 2745cdd | FAIL — new cancellation harness observation bug |
| [37092781022](https://github.com/ShiroDaifuku/PersonalDeepSeek-iOS/actions/runs/37092781022) | 395c608 | FAIL — first Bing timeout; ordinary/migration/native/5 Memory trials passed |
| [37112916413](https://github.com/ShiroDaifuku/PersonalDeepSeek-iOS/actions/runs/37112916413) | f39577a | CANCELLED before live evaluation; query/provider recall diagnosed |
| [37113103474](https://github.com/ShiroDaifuku/PersonalDeepSeek-iOS/actions/runs/37113103474) | 166c869 | FAIL — full real Research completed; new directory-URL fact verifier failed |
| [37114253350](https://github.com/ShiroDaifuku/PersonalDeepSeek-iOS/actions/runs/37114253350) | 77326fd | SUCCESS — corrected verifier, full structural/migration + real Research follow-up |

Only changed implementation files: `ios/Tests/IntegrationAcceptanceTests.swift`, new independent test method/wrapper in `ios/Tests/MemoryBackfillRealEvaluationTests.swift`, `.github/workflows/ios-integration-acceptance.yml`, opt-in entry in `.github/workflows/ios-memory-validation.yml`, this report and diagnostic JSON snapshots.

Raw/public/synthetic JSON evidence is under `docs/evaluations/integration-acceptance-2026-10-03/`. Secret-bearing xctestrun/DerivedData are never uploaded. Original workspace and Native worktree were not modified.

## N. Capability Freeze

| Capability | Status |
|---|---|
| Main-model native tools, tool-call SSE, matching tool IDs | Validated; frozen |
| Bounded native multi-round loop and reasoning re-entry | Validated; frozen |
| Persisted ToolExecutionRecord / future-turn awareness | Existing accepted capability; unchanged |
| Foreground explicit Research gather/budget/synthesis | Real E2E PASS with Bing RSS; frozen |
| Profile/Memory coexistence and direct raw-evidence isolation | Validated at component/storage boundary |
| Autonomous mutation tools | NO |
| ResearchRun persistence, resume/background research | NO |
| Cloud/sub-agent research orchestration | NO |
| Session Recall | NO |

## O. Final Gate

**PASS — integrated Tool Runtime + Research is production-baseline ready**

| Blocking gate | Result in validated provider condition |
|---|---|
| Explicit Research route failure | 0 |
| Research gather / synthesis failure | 0 / 0 |
| Duplicate current Research evidence | 0 |
| Explicit Research invoking native web_search | 0 |
| Ordinary latest routing to Research | 0 |
| Thinking protocol re-entry failure | 0 |
| Direct raw-evidence Memory/Profile contamination | 0 |
| Migration regression | 0 |
| New build/ordinary XCTest regression | 0 |

No production defect has been demonstrated by the recorded failures. This does not claim zero network failures or perfect search relevance. Bing RSS has weak recall for specialized queries, the initial timeout remains, and physical-device UI/cold-network behavior is not validated by this phase.

The PASS is based on the final real provider E2E, unchanged production source and separately recorded native/Memory results. It does not overwrite any earlier failed/cancelled CI outcome or claim all past network attempts succeeded.

Work completed and stopped. No main merge, IPA, deployment or new feature work.
