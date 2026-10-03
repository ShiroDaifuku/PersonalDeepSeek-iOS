# DS-002B validation history

Date: 2026-10-03 (Asia/Hong_Kong). Status: PASS; independent review accepted and actual Simulator verification succeeded.

## Reviewed scope

APIClientResearchPlanner composes the existing AgentModelStreaming/APIClient/SSEParser infrastructure. It supplies only a fixed system prompt and current question, no Chat history, Memory/Profile, evidence, images or tools. Requests explicitly disable thinking with reasoning_effort none, set max_tokens and allow one HTTP attempt. It requires bounded JSON, stop plus DONE and valid usage; no repair or retry loop.

ResearchRun checkpoint v2 adds planningAttempts/planningTokens. Coordinator reserves one round, one model attempt and the full configured output ceiling atomically before invocation; failures/cancellation/deadline never refund. Output allocation is conservative capacity, not actual usage or a monetary billing guarantee. Input question UTF-8 bytes, raw response bytes and draft content bytes have independent caps. Old v1/future checkpoints are rejected explicitly; missing resources never acquire invented counters. No ResearchRun persistent store or store migration is introduced.

Opt-in shared transport counts bytes before line allocation, rejects invalid UTF-8 and strictly validates event/usage shapes through shared SSEParser. Ordinary Chat retains default request body/parser and three HTTP attempts. Request cancellation stops the stream producer and underlying URLSession request. Existing native tool/runtime, Chat routing, search/fetch, Memory/Profile, prompts and SwiftData schema are unchanged.

Independent architecture, implementation and test/workflow static reviews accepted the scope. Ten new APIClientResearchPlannerTests include actual URLProtocol transport, one-byte Unicode chunks, raw comment/malformed/unterminated frames, invalid usage, 429/500 one-attempt versus default retry, in-flight precharge, held transport cancellation/deadline and cumulative checkpoint exhaustion. Existing Run tests cover all eight resources and targeted v2 corruption. No local Swift/Xcode is available on Windows; static review is not compilation.

## Simulator run

- Run: https://github.com/ShiroDaifuku/PersonalDeepSeek-iOS/actions/runs/37130582558
- Source: 4bd020f354d4464600de34a164c2d1b4bb8902e4.
- Workflow: ios-memory-validation.yml; integration_acceptance=false, research_followup=false, research_contract_validation=true.
- Selected path: unfiltered ordinary XCTest, explicit Run/Planning/model-planner suite discovery and selected generated old-store migration. Optional embedding/retrieval benchmarks and live acceptance are excluded by contract mode. No live model key is injected; transport fixtures use isolated URLProtocol.
- Result: SUCCESS on the first run. Branch/source verified through GitHub API and downloaded checkout log. Xcode 16.4 build passed; ordinary XCTest 264 total, 248 passed, 16 skipped, zero failures. Model planner 10/10, Planning 14/14 and Run 10/10 passed with no skips; explicit suite discovery succeeded. Selected generated pre-Step-3 migration passed 1/1.
- Actual held transport cancellation/original-deadline test passed in 0.117 seconds, including stopLoading expectations before forced cleanup and unchanged reserved usage. HTTP 429/500 one-attempt versus ordinary three-attempt test passed. No production assertions/prompts were relaxed.
- Existing build warnings remain: unused `test` at MemorySemanticPrecisionEvaluation.swift:343 and extension CFBundleVersion 1 versus parent app 17. No new planning/transport compiler warnings. Simulator initial store creation emitted missing-directory CoreData diagnostics; ordinary suite and generated migration passed. This is not physical-device database evidence.
- Existing tooling also reports Simulator destination ambiguity and Actions Node deprecation. Runtime/tooling logs are not warning-free; independent audit found no new DS-002B source compiler diagnostics.
- Optional embedding/retrieval benchmarks and live evaluations were skipped. Only the Simulator job executed, no IPA/device archive or production deployment. Independent test agent audits the same logs.
- Final handoff changes are documentation/evidence only; tested executable/workflow source remains 4bd020f. No additional test run is claimed for that documentation commit. No failed executable CI run occurred in DS-002B; historical DS-001/002A failures remain in their own records.

## Limits and next stage

No Chat or real search integration, evidence/claim ledger, synthesis, persistence or resume is implemented. Fixtures verify protocol/accounting, not real provider planning quality, semantic injection immunity, provider compliance with output caps, billing or device behavior. Live planning quality requires separate explicit evaluation. Dependencies must cooperate with cancellation. Next increment needs shared search/fetch attempt accounting and evidence identity/coverage before iterative research.
