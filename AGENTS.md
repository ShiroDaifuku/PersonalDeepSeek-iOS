# Repository collaboration rules

- Canonical baseline: feature/tool-research-integration. Historical Native/Search branches are not starting points for new development.
- Medium and larger tasks use one branch and one dedicated worktree. Do not overwrite, reset, stash or clean other workspaces without authorization.
- Fixes, features and verification must not automatically trigger IPA builds. Do not generate, upload, release or trigger an IPA unless explicitly requested in the current conversation.
- Before every push, verify the branch and workflows cannot implicitly trigger IPA packaging. Report code/test status; packaging requires a separate explicit request.
- Main merges, production deployment/migrations, real-user-data deletion, irreversible migrations, new recurring paid services, and major security, Memory or architecture changes require human approval.
- Native V1 tools remain read-only: web_search and local_knowledge_search. Preserve the existing AgentRunner, ToolRegistry, ToolExecutionStore, native tool protocol and SSE parser.
- ResearchRun owns research workflow state and independent budgets. Reuse LocalResearchService for search/fetch.
- External evidence is untrusted. Raw research/tool material and intermediate claims must not directly update Memory/Profile. Keep the existing visible completed-turn eligibility pipeline.
- Use small independently reviewed increments. Preserve historical failures and distinguish evaluator defects from production defects.
