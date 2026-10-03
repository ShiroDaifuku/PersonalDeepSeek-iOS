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

Current context ceilings are characters, not exact model tokens: 48,000 available input, 12,000 history, 26,000 evidence. They do not replace research work/cost budgets. Legacy ResearchView has no RootView entry; extend the real Chat research path first.
