# Engineering architecture map

Supplements the root architecture contract with the accepted integration baseline.

| Boundary | Current implementation |
| --- | --- |
| Chat | ChatView: visible messages, routing, immutable personal context, completion eligibility |
| Memory | Service/Processor/Extraction/Store/Retrieval/Backfill: completed visible turns and validated changes |
| Profile | UserProfileManager/ProfileContext: aggregate validated memory, read-only chat snapshot |
| Ordinary runtime | AgentRunner/AgentModels/AgentTools: native protocol, bounded rounds, repeat protection |
| Tool audit | ToolExecutionModels/Store/ToolHistoryContext: bounded conversation audit and awareness |
| Search/fetch | LocalResearchService: provider fallback, URL/DNS/redirect checks, extraction, injectable dependencies |
| Research today | ChatView -> gatherWithMetadata -> researchMessages -> AgentRunner with tools disabled -> final answer |
| Context | MemoryContext/ResearchContextBudget: Profile, history, tool history, evidence, Memory, clock, user/images |
| Transport | APIClient/SSEParser: shared request serialization and stream processing |
| Local persistence | SwiftData in PersonalDeepSeekApp: messages, knowledge, Memory/Profile and tool records |
| Cloudflare | Scheduled tasks, D1/Queue/Cron, quotas and APNs; not interactive Research orchestration |
| ResearchRun target | Independent workflow, budgets and internal checkpoints; shared search/transport |
| Accepted planning component | ResearchPlanningCoordinator + APIClientResearchPlanner: host-owned validated plans, one bounded shared model attempt, cumulative output allocation; not wired into Chat |
| Accepted collection component | Same coordinator + opt-in LocalResearchService admission: logical query/provider HTTP/page-hop counters, bounded transient run-bound source snapshot |
| Accepted evidence component | Same coordinator + ResearchEvidenceLedger: bounded immutable source/query/question graph, page/snippet segments and full context digests; novel metadata reservations, no Chat integration |
| Accepted retrieval coverage component | Same coordinator + ResearchCoverageReport: all planned questions, page/snippet/source references, availability and independent gaps, full ledger verification/context digest; no factual support or automatic refinement |

Current context ceilings are characters, not exact model tokens: 48,000 available input, 12,000 history, 26,000 evidence. They do not replace research work/cost budgets. Legacy ResearchView has no RootView entry; extend the real Chat research path first.

ResearchRun checkpoint v3 requires nine cumulative resource dimensions, including planningAttempts/planningTokens and searchRequests. It rejects v1/v2/future checkpoints; no persistent ResearchRun migration exists. PlanningTokens is reserved output capacity, not actual billing. Model planning has separate input/raw-response/content byte caps and opt-in strict shared SSE validation; ordinary Chat request/parser defaults are retained. Collection admission counts application search requests and every page redirect hop, with no refunds on failure/cancel. Ledger v1 reuses collected text charges and reserves new textual metadata, including 128 context digest characters even for empty results. Coverage v1 reserves its new64-character full-ledger digest and every retained reference/label occurrence; report bounds reject rather than silently drop question rows. Expected-host decode compares full context and deterministic projection; hashes/Codable do not authenticate history or create storage. Retained caps do not bound full downloads/transient parsing. Controlled refinement, factual support and durable lifecycle remain future stages.
